# Changelog

## 1.2.0

- Added a marketplace icon (`icon/icon.png`) and a README banner (`icon/banner.png`, excluded from the packaged VSIX).

## 1.1.2

- Fixed a real, confirmed quoting bug in `Install-PublicKey` and `Remove-RemotePublicKey`: the remote bash command (containing embedded double quotes) was built as one PowerShell string and passed as a single native argument to `ssh.exe`. This was found, during live testing against a real host, to corrupt the command - the quoting was lost somewhere between PowerShell and the remote shell, causing `$key` to be word-split into separate `grep` arguments instead of staying one quoted value. Fixed by base64-encoding the entire remote script and decoding/running it on the far end (`echo <base64> | base64 -d | sh`) instead of embedding quoted shell text on the ssh command line at all - base64 text has no shell metacharacters, so there is nothing left to mis-quote. Verified against the exact failing case (a pre-existing key with a comment containing an apostrophe and double quotes) with a mock `ssh.exe` (to confirm the command survives PowerShell's argument passing intact) and by actually executing the decoded script through bash (to confirm the shell logic itself, and its idempotency on a second run).
- Known related finding (not a bug in this extension): during that same live test, the target account appears to have accepted a blank/non-interactive password submission. That's worth checking directly on the server - if the account truly has no password set, that's a server-side security issue independent of this tool.

## 1.1.1

- Fixed the interactive password/regenerate window not appearing at all: spawning PowerShell directly with `windowsHide:false` does not reliably create a visible console window from inside the real VS Code extension host process tree. Replaced it with a hidden wrapper process that launches the visible window via `Start-Process -WindowStyle Normal`, which is documented to always create one.
- Fixed a real quoting bug found while testing the above: passing the host alias through `Start-Process -ArgumentList` corrupted values containing an embedded single quote, and an array-based `-ArgumentList` also mishandled a script path containing spaces. The host alias is now passed via an environment variable (never re-parsed, so any character survives intact) and the script path via a single pre-quoted argument string instead of an array.
- Fixed a logging bug where a failed process (non-zero exit code) was logged as `OK` in the SSH Key Manager output channel instead of `FAILED`.

## 1.1.0

- Renamed the command id to `sshKeyManager.open` (was the prototype `sshkey.run`).
- Rewrote subprocess handling around one centralized runner: every SSH test, hidden PowerShell call, and interactive PowerShell call now has an explicit timeout and is force-terminated (whole process tree) if it hangs, so progress notifications can no longer stay open forever.
- Fixed a bug where the interactive password/regenerate flow referenced an undefined variable and would throw instead of completing.
- Added shared-`IdentityFile` detection before key regeneration: if the current key is referenced by another `Host` block, it is left untouched and a new dedicated key is generated for the selected host instead.
- Added `ConnectTimeout` to the remote key-installation and key-removal SSH calls to avoid indefinite hangs against unreachable or slow hosts.
- `npm run check` now also validates `extension.js` with `node --check` and validates `scripts/setup-ssh-key.ps1` by parsing it as a PowerShell script block, in addition to the source hygiene scan.
- Fixed mojibake and a stray BOM in README.md.

## 1.0.0

- Initial open-source release.
- Native VS Code host and action pickers.
- Setup, repair, test, and regenerate SSH keys.
- Bundled PowerShell automation.
- Automatic SSH config backup and repair.
- Generic key comments with no machine or user identity embedded.
