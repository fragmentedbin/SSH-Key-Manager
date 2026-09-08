param(
    [string]$HostAlias,

    [switch]$Regenerate,

    [switch]$NonInteractiveMode
)

$ErrorActionPreference = 'Stop'

# When launched through the interactive password window, the caller passes
# HostAlias/Regenerate via environment variables instead of command-line
# parameters (Start-Process's -ArgumentList cannot reliably carry arbitrary
# text - see extension.js). Command-line values still take precedence so
# direct invocation (eg. the non-interactive Setup / Repair path) keeps
# working unchanged.
if ([string]::IsNullOrWhiteSpace($HostAlias) -and $env:SSHKEYMGR_HOST_ALIAS) {
    $HostAlias = $env:SSHKEYMGR_HOST_ALIAS
}

if (-not $Regenerate -and $env:SSHKEYMGR_REGENERATE -eq '1') {
    $Regenerate = $true
}

if ([string]::IsNullOrWhiteSpace($HostAlias)) {
    throw 'HostAlias was not provided.'
}

$SshDir = Join-Path $env:USERPROFILE '.ssh'
$ConfigPath = Join-Path $SshDir 'config'
$SshExe = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$SshKeygenExe = Join-Path $env:WINDIR 'System32\OpenSSH\ssh-keygen.exe'
$KeyComment = 'vscode-sshkey-manager'

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Assert-Requirements {
    if (!(Test-Path $ConfigPath)) {
        throw "SSH config not found: $ConfigPath"
    }

    if (!(Test-Path $SshExe)) {
        throw 'Windows OpenSSH Client was not found.'
    }

    if (!(Test-Path $SshKeygenExe)) {
        throw 'ssh-keygen.exe was not found.'
    }
}

function Normalize-KeyPath([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $value = $Value.Trim().Trim('"')

    if ($value.StartsWith('~/') -or $value.StartsWith('~\')) {
        $value = Join-Path $env:USERPROFILE $value.Substring(2)
    }

    $value = [Environment]::ExpandEnvironmentVariables($value)
    return $value
}

function Get-HostBlock([string]$Alias) {
    $lines = @(Get-Content $ConfigPath)
    $start = -1
    $end = $lines.Count

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*Host\s+(.+?)\s*$') {
            $aliases = @($matches[1] -split '\s+')

            if ($start -ge 0) {
                $end = $i
                break
            }

            if ($aliases -contains $Alias) {
                $start = $i
            }
        }
    }

    if ($start -lt 0) {
        throw "Host '$Alias' not found in $ConfigPath"
    }

    return [pscustomobject]@{
        Lines = $lines
        Start = $start
        End = $end
    }
}

function Get-ExplicitIdentityFile([string]$Alias) {
    $block = Get-HostBlock $Alias

    for ($i = $block.Start + 1; $i -lt $block.End; $i++) {
        if ($block.Lines[$i] -match '^\s*IdentityFile\s+(.+?)\s*$') {
            return Normalize-KeyPath $matches[1]
        }
    }

    return $null
}

function Get-DedicatedKeyPath([string]$Alias) {
    $safeAlias = $Alias -replace '[^a-zA-Z0-9._-]', '_'
    return Join-Path $SshDir "id_ed25519-vscode-$safeAlias"
}

# Splits the whole config into Host blocks (alias list + line range), the
# same way Get-HostBlock does for a single alias, so callers can inspect
# every block instead of just one.
function Get-AllHostBlocks([string[]]$Lines) {
    $blocks = @()
    $current = $null

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*Host\s+(.+?)\s*$') {
            if ($current) {
                $current.End = $i
                $blocks += $current
            }

            $aliases = @($matches[1] -split '\s+') | Where-Object {
                $_ -and $_ -notmatch '[*?]'
            }

            $current = [pscustomobject]@{
                Aliases = $aliases
                Start   = $i
                End     = $Lines.Count
            }
        }
    }

    if ($current) {
        $current.End = $Lines.Count
        $blocks += $current
    }

    return $blocks
}

function Get-IdentityFileFromBlock($Block, [string[]]$Lines) {
    for ($i = $Block.Start + 1; $i -lt $Block.End; $i++) {
        if ($Lines[$i] -match '^\s*IdentityFile\s+(.+?)\s*$') {
            return Normalize-KeyPath $matches[1]
        }
    }

    return $null
}

# Returns the aliases (other than $Alias) whose Host block explicitly
# references the same IdentityFile. Regeneration must never overwrite a key
# that is shared this way - it would silently break those other hosts.
function Find-SharedIdentityHosts([string]$Alias, [string]$IdentityPath) {
    if ([string]::IsNullOrWhiteSpace($IdentityPath)) {
        return @()
    }

    $lines = @(Get-Content $ConfigPath)
    $blocks = Get-AllHostBlocks $lines
    $normalizedTarget = $IdentityPath.ToLowerInvariant()
    $sharedWith = @()

    foreach ($block in $blocks) {
        if ($block.Aliases -contains $Alias) {
            continue
        }

        $candidate = Get-IdentityFileFromBlock $block $lines
        if ($candidate -and $candidate.ToLowerInvariant() -eq $normalizedTarget) {
            $sharedWith += ($block.Aliases -join ',')
        }
    }

    return $sharedWith
}

function Backup-Config {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = "$ConfigPath.backup-$timestamp"
    Copy-Item $ConfigPath $backup -Force
    Write-Ok "SSH config backup: $backup"
}

function Backup-KeyPair([string]$PrivateKey) {
    if (!(Test-Path $PrivateKey) -and !(Test-Path "$PrivateKey.pub")) {
        return $null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir = Join-Path $SshDir "key-backup-$timestamp"
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    if (Test-Path $PrivateKey) {
        Copy-Item $PrivateKey $backupDir -Force
    }

    if (Test-Path "$PrivateKey.pub") {
        Copy-Item "$PrivateKey.pub" $backupDir -Force
    }

    Write-Ok "Key backup: $backupDir"
    return $backupDir
}

function Generate-Key([string]$PrivateKey) {
    Write-Step "Generating ED25519 key"

    $parent = Split-Path $PrivateKey -Parent
    if (!(Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $arguments = @(
        '-t', 'ed25519',
        '-a', '100',
        '-f', $PrivateKey,
        '-C', $KeyComment,
        '-N', '""'
    )

    & $SshKeygenExe @arguments

    if ($LASTEXITCODE -ne 0) {
        throw 'ssh-keygen failed.'
    }

    Write-Ok "Generated key: $PrivateKey"
}

function Ensure-PublicKey([string]$PrivateKey) {
    $publicKey = "$PrivateKey.pub"

    if (Test-Path $publicKey) {
        return $publicKey
    }

    if (!(Test-Path $PrivateKey)) {
        throw "Private key not found: $PrivateKey"
    }

    $public = & $SshKeygenExe -y -f $PrivateKey
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($public)) {
        throw 'Unable to derive public key from the private key.'
    }

    Set-Content -Path $publicKey -Value "$public $KeyComment" -Encoding ASCII
    Write-Ok "Recreated public key: $publicKey"
    return $publicKey
}

# Runs a POSIX shell script on the remote host without embedding any of its
# text as quoted arguments on the ssh command line. The whole script is
# base64-encoded and decoded on the far end instead - passing quoted bash
# text (containing embedded double quotes) as a single native argument
# through PowerShell -> ssh.exe -> the remote shell was tested against a
# live host and found to corrupt the quoting, splitting a value that should
# have stayed one argument. Base64 text contains no shell metacharacters at
# all, so there is nothing left to mis-quote.
function Invoke-RemoteScript([string]$Alias, [string]$ScriptBody, [string[]]$SshArgs = @()) {
    $scriptBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ScriptBody))
    $remoteCommand = "echo $scriptBase64 | base64 -d | sh"

    & $SshExe @SshArgs $Alias $remoteCommand
    return $LASTEXITCODE
}

function Install-PublicKey([string]$Alias, [string]$PublicKey) {
    Write-Step "Installing public key on $Alias"

    $key = (Get-Content $PublicKey -Raw).Trim()

    if ([string]::IsNullOrWhiteSpace($key)) {
        throw "Public key is empty: $PublicKey"
    }

    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($key)
    $keyBase64 = [Convert]::ToBase64String($keyBytes)

    $scriptBody = @'
set -e
umask 077
mkdir -p ~/.ssh
touch ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
key="$(printf '%s' '__KEY_BASE64__' | base64 -d)"
grep -qxF "$key" ~/.ssh/authorized_keys || printf '%s\n' "$key" >> ~/.ssh/authorized_keys
'@.Replace('__KEY_BASE64__', $keyBase64)

    # ConnectTimeout only bounds the TCP connect phase, not password entry,
    # so this cannot cut off an interactive password prompt.
    $exitCode = Invoke-RemoteScript -Alias $Alias -ScriptBody $scriptBody -SshArgs @('-o', 'ConnectTimeout=15')

    if ($exitCode -ne 0) {
        throw 'Unable to install public key.'
    }

    Write-Ok 'Public key installed.'
}
function Update-SshConfig([string]$Alias, [string]$IdentityFile) {
    Write-Step 'Updating SSH config'
    Backup-Config

    $block = Get-HostBlock $Alias
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $block.Lines) {
        $lines.Add($line)
    }

    $hostLine = $block.Lines[$block.Start]
    $aliasCount = 1
    if ($hostLine -match '^\s*Host\s+(.+?)\s*$') {
        $aliasCount = @($matches[1] -split '\s+').Count
    }

    if ($aliasCount -gt 1) {
        throw "Host '$Alias' shares one Host block with other aliases. Split it into a dedicated Host block before using automatic config repair."
    }

    $identityIndex = -1
    $identitiesOnlyIndex = -1

    for ($i = $block.Start + 1; $i -lt $block.End; $i++) {
        if ($lines[$i] -match '^\s*IdentityFile\s+') {
            $identityIndex = $i
        }
        elseif ($lines[$i] -match '^\s*IdentitiesOnly\s+') {
            $identitiesOnlyIndex = $i
        }
    }

    if ($identityIndex -ge 0) {
        $lines[$identityIndex] = "    IdentityFile $IdentityFile"
    }
    else {
        $insertAt = $block.End
        $lines.Insert($insertAt, "    IdentityFile $IdentityFile")
        $block.End++

        if ($identitiesOnlyIndex -ge $insertAt) {
            $identitiesOnlyIndex++
        }
    }

    if ($identitiesOnlyIndex -ge 0) {
        $lines[$identitiesOnlyIndex] = '    IdentitiesOnly yes'
    }
    else {
        $lines.Insert($block.End, '    IdentitiesOnly yes')
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($ConfigPath, $lines, $utf8)
    Write-Ok 'SSH config updated.'
}

function Test-KeyLogin([string]$Alias) {
    Write-Step 'Testing passwordless SSH'

    $output = & $SshExe `
        -o BatchMode=yes `
        -o ConnectTimeout=8 `
        -o ConnectionAttempts=1 `
        -o ServerAliveInterval=3 `
        -o ServerAliveCountMax=1 `
        $Alias `
        'printf SSH_KEY_AUTH_SUCCESS' 2>&1

    if ($LASTEXITCODE -eq 0 -and ($output -join "`n") -match 'SSH_KEY_AUTH_SUCCESS') {
        Write-Ok 'Passwordless SSH works.'
        return $true
    }

    Write-Warn 'Passwordless SSH test failed.'
    return $false
}

function Remove-RemotePublicKey([string]$Alias, [string]$PublicKeyText) {
    if ([string]::IsNullOrWhiteSpace($PublicKeyText)) {
        return
    }

    $key = $PublicKeyText.Trim()
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($key)
    $keyBase64 = [Convert]::ToBase64String($keyBytes)

    $scriptBody = @'
if [ -f ~/.ssh/authorized_keys ]; then
    key="$(printf '%s' '__KEY_BASE64__' | base64 -d)"
    tmp="$HOME/.ssh/authorized_keys.sshkeymgr.tmp"
    grep -vxF "$key" "$HOME/.ssh/authorized_keys" > "$tmp" || true
    mv "$tmp" "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
fi
'@.Replace('__KEY_BASE64__', $keyBase64)

    Invoke-RemoteScript -Alias $Alias -ScriptBody $scriptBody -SshArgs @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15') | Out-Null
}

if (!$NonInteractiveMode) {
    Write-Host ''
    Write-Host 'SSH Key Manager' -ForegroundColor Cyan
    Write-Host "Host: $HostAlias"
    Write-Host 'Please enter the server password when prompted.'
    Write-Host ''
}

Assert-Requirements

Write-Step "Reading SSH configuration for $HostAlias"

$identity = Get-ExplicitIdentityFile $HostAlias
if (!$identity) {
    $identity = Get-DedicatedKeyPath $HostAlias
    Write-Warn 'No dedicated IdentityFile is configured.'
    Write-Host "Will use: $identity"
}
else {
    Write-Ok "Existing IdentityFile: $identity"
}

if ($Regenerate) {
    if ($NonInteractiveMode) {
        throw 'Regeneration requires interactive mode.'
    }

    Write-Warn 'Regeneration will replace the local key after a backup is created.'
    $answer = Read-Host 'Type YES to continue'
    if ($answer -ne 'YES') {
        Write-Warn 'Regeneration cancelled.'
        exit 2
    }

    $sharedWith = Find-SharedIdentityHosts $HostAlias $identity
    $isShared = $sharedWith.Count -gt 0
    $targetIdentity = $identity

    if ($isShared) {
        Write-Warn "The key '$identity' is also referenced by: $($sharedWith -join ', ')."
        Write-Warn 'It will not be replaced in place. Generating a new dedicated key for this host instead.'
        $targetIdentity = Get-DedicatedKeyPath $HostAlias
    }

    $oldPublicKey = $null
    if (Test-Path "$targetIdentity.pub") {
        $oldPublicKey = (Get-Content "$targetIdentity.pub" -Raw).Trim()
    }

    Backup-KeyPair $targetIdentity | Out-Null

    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $newIdentity = "$targetIdentity.new-$timestamp"
    Generate-Key $newIdentity
    Install-PublicKey $HostAlias "$newIdentity.pub"

    Move-Item $newIdentity $targetIdentity -Force
    Move-Item "$newIdentity.pub" "$targetIdentity.pub" -Force

    Update-SshConfig $HostAlias $targetIdentity

    if (!(Test-KeyLogin $HostAlias)) {
        throw 'New key was installed, but the passwordless authentication test failed. Restore the key backup if necessary.'
    }

    # Only remove the old public key from the remote host when it was not
    # shared with other Host blocks - a shared key must be left fully intact.
    if ($oldPublicKey -and !$isShared) {
        Remove-RemotePublicKey $HostAlias $oldPublicKey
    }

    Write-Ok "SSH key regeneration completed for $HostAlias"
    exit 0
}

if (!(Test-Path $identity)) {
    Generate-Key $identity
}

$publicKey = Ensure-PublicKey $identity
Install-PublicKey $HostAlias $publicKey
Update-SshConfig $HostAlias $identity

if (!(Test-KeyLogin $HostAlias)) {
    throw 'Setup completed, but passwordless SSH authentication did not pass the final test.'
}

Write-Ok "SSH setup completed for $HostAlias"
