![SSH Key Manager](icon/banner.png)

# SSH Key Manager for VS Code

A small open-source VS Code extension that helps Windows, macOS, and Linux users set up and maintain passwordless SSH access for hosts already defined in `~/.ssh/config`.

It is designed for people who use **VS Code Remote - SSH** and want to stop re-entering server passwords while still using the system OpenSSH client.

## Features

- Native VS Code host picker sourced from your local `~/.ssh/config`
- **Setup / Repair** passwordless SSH
- **Test** public-key authentication without prompting for a password
- **Regenerate** a dedicated key with local backups
- Automatically adds or repairs `IdentityFile` and `IdentitiesOnly yes`
- Generates ED25519 keys with a generic `vscode-sshkey-manager` comment
- Bundles the setup script (PowerShell on Windows, a POSIX shell script on macOS/Linux) inside the VSIX
- Runs as a local/UI extension, including when the current VS Code window is connected over Remote - SSH
- Uses the system's own OpenSSH for authentication; the extension does not capture or store server passwords

## Requirements

- Windows, macOS, or Linux as the **local VS Code client**
- VS Code 1.90 or newer
- An OpenSSH client installed (Windows OpenSSH Client on Windows; macOS and most Linux distributions ship one at `/usr/bin/ssh` already)
- On Linux, a terminal emulator for the password-entry window: GNOME Terminal, Konsole, xfce4-terminal, or xterm (tried in that order - the extension has no way to prompt for a password without one)
- At least one host in `~/.ssh/config` (`%USERPROFILE%\.ssh\config` on Windows)
- A POSIX-compatible SSH server (Linux/Unix is the primary target)

Initial key installation may require the server account password once. If another authentication method already works, setup can often complete without a password prompt.

## Example SSH config

```sshconfig
Host production-server
    HostName server.example.com
    User deploy
    Port 22
```

After **Setup / Repair**, the extension adds a dedicated identity automatically:

```sshconfig
Host production-server
    HostName server.example.com
    User deploy
    Port 22
    IdentityFile <your-home>\.ssh\id_ed25519-vscode-production-server
    IdentitiesOnly yes
```

No server names, usernames, addresses, or credentials are hardcoded in the extension.

## Install a VSIX

1. Download the `.vsix` from a release.
2. In VS Code, open **Extensions**.
3. Open the `...` menu.
4. Choose **Install from VSIX...**.
5. Reload VS Code.

Or from a local terminal:

```powershell
code --install-extension .\vscode-ssh-key-manager-1.3.2.vsix
```

## Usage

Open the Command Palette:

```text
Ctrl + Shift + P
```

Run:

```text
SSH Key Manager: Open SSH Key Manager
```

Choose a host, then choose:

- **Setup / Repair** - ensure a dedicated key exists, install its public key, and repair the SSH config
- **Test** - verify public-key login using `BatchMode=yes`
- **Regenerate Key** - back up the current key, create a replacement, install it, test it, and retain a local backup

### Why can a terminal window appear?

VS Code extensions running locally in a Remote - SSH window cannot reliably create a local integrated terminal through the public extension API. When OpenSSH must ask for a server password, SSH Key Manager opens a local terminal window (PowerShell on Windows; Terminal.app on macOS; the first available terminal emulator on Linux) so the password is entered directly into the system `ssh` process.

The extension does **not** receive the password.

## Security model

- Private keys are created under the current user's `.ssh` directory.
- Private key contents are never sent by the extension.
- Only the public key is appended to the remote account's `~/.ssh/authorized_keys`.
- Password entry is handled by the system's own OpenSSH client.
- SSH config is backed up before automatic modification.
- Existing keys are backed up before regeneration.
- The generated public-key comment is generic and does not include the local username or computer name.
- Before regenerating, the extension checks whether the current key's `IdentityFile` is referenced by any other `Host` block. If it is shared, the shared key is left untouched and a new dedicated key is generated for the selected host instead.

## Current limitations

- macOS and Linux support is newer than the Windows support and has had less real-world testing - please report anything that doesn't work as expected.
- On Linux specifically, the password-entry window depends on finding a supported terminal emulator installed (see Requirements) - there is no single standard terminal the way there is on Windows/macOS.
- Automatic config repair expects the selected alias to have its own `Host` block. If one `Host` line contains multiple aliases, split the selected alias into its own block before running Setup / Repair.
- Linux/Unix SSH servers are the primary supported remote target.
- The remote account needs `sh` and `base64` available (present on effectively all Linux/Unix systems) - the key install/removal commands are transmitted as base64 and decoded on the remote end rather than as quoted shell text, to avoid fragile shell-to-shell quoting.

## Development

Clone the repository and install the development dependency:

```powershell
npm install
```

Run the source hygiene check:

```powershell
npm run check
```

Package a VSIX:

```powershell
npm run package
```

The resulting `.vsix` can be installed locally with:

```powershell
code --install-extension .\vscode-ssh-key-manager-1.3.2.vsix --force
```

## Releasing

Push a tag such as:

```bash
git tag v1.3.2
git push origin v1.3.2
```

The included GitHub Actions workflow packages the VSIX and attaches it to a GitHub Release.

## License

MIT. See the LICENSE file.

