# install-scripts

This repository hosts the installers used to put the Merlin Guild
desktop app on your machine. The scripts are intentionally tiny and
inspectable – read them before you run them.

- **`install.ps1`** – Windows (PowerShell 5.1+).
- **`install.sh`** – macOS and Linux *(the bundles themselves are not
  published yet; the script is ready for when they are)*.

## How it works

There are three acquisition modes. The first one is what a paying
member uses. The other two exist for dev and closed-beta.

### 1. GitHub mode (default)

```powershell
iwr https://raw.githubusercontent.com/merlinguild/install-scripts/main/install.ps1 -UseBasicParsing | iex
```

```bash
curl -fsSL https://raw.githubusercontent.com/merlinguild/install-scripts/main/install.sh | bash
```

The installer:

1. Starts a **GitHub OAuth device flow** and prints a short code for
   you to enter at <https://github.com/login/device>.
2. Confirms you are an active member of the `merlinguild/members`
   team.
3. Downloads the latest bundle from the private
   `merlinguild/artifacts` release – plus its `.sig` signature
   sidecar – using the GitHub API.
4. Runs the platform-native installer (`msiexec` on Windows, `.dmg`
   copy on macOS, `.AppImage` copy on Linux).
5. Persists the OAuth token at
   `%LOCALAPPDATA%\.merlinguild\token` (Windows) or
   `~/.merlinguild/token` (Unix) so the in-app updater can reuse it
   for future releases.

### 2. Local file mode

```powershell
.\install.ps1 -LocalPath .\MerlinGuild_0.1.0_x64_en-US.msi
```

```bash
./install.sh --local-path ./MerlinGuild_0.1.0_x64.dmg
```

Skips GitHub entirely. Used for smoke-testing a fresh
`cargo tauri build` on the developer's own machine. Signature
verification is **optional** in this mode (use
`-RequireSignature` / `--require-signature` to force it).

### 3. Direct URL mode

```powershell
$env:MG_LOCAL_URL = 'https://share.example.com/mg-0.1.0.msi'
iwr https://raw.githubusercontent.com/merlinguild/install-scripts/main/install.ps1 -UseBasicParsing | iex
```

```bash
MG_LOCAL_URL='https://share.example.com/mg.dmg' \
curl -fsSL https://raw.githubusercontent.com/merlinguild/install-scripts/main/install.sh | bash
```

Also skips GitHub. Used to give a friend a one-off build without
requiring them to have a GitHub account. The script **requires** a
`.sig` file alongside the main URL (just append `.sig` to the path
when uploading). Override with `-SkipSignatureCheck` /
`--skip-signature-check` only if you really know what you are doing.

## Parameters

### `install.ps1`

| Flag / env | Purpose |
|------------|---------|
| `-LocalPath <msi>` / `$env:MG_LOCAL_PATH` | Install a local file. |
| `-LocalUrl <url>` / `$env:MG_LOCAL_URL` | Install from any URL. |
| `-Token <ghp_...>` / `$env:MG_TOKEN` | Pre-obtained GitHub token. |
| `-RequireSignature` | Fail if `.sig` is absent in local-file mode. |
| `-SkipSignatureCheck` | Allow install without `.sig` in URL mode. |

### `install.sh`

| Flag / env | Purpose |
|------------|---------|
| `--local-path <file>` / `MG_LOCAL_PATH` | Install a local file. |
| `--local-url <url>` / `MG_LOCAL_URL` | Install from any URL. |
| `--token <ghp_...>` / `MG_TOKEN` | Pre-obtained GitHub token. |
| `--require-signature` | Fail if `.sig` is absent in local-file mode. |
| `--skip-signature-check` | Allow install without `.sig` in URL mode. |

## Getting access

Membership is managed through the `merlinguild/members` GitHub team.
Ping the dev on Telegram to request an invitation. Once accepted,
the same one-liner above installs the app.

## Reporting issues

If the installer fails, copy the terminal output and attach it to a
message to the admin. The scripts print explicit error reasons from
GitHub's API, `msiexec`, and `hdiutil` – they usually say exactly what
went wrong.
