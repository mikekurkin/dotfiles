# Minimal CLI installation manifest

Added formulae are kept only for explicit bootstrap/configuration dependencies. Original formula declarations are retained through their current names. Apple Command Line Tools provide Git; macOS provides less and grep. Libraries/build tools are not declared solely because they were installed on the old machine. Homebrew may still install required transitive dependencies.

| Formula | Reason retained |
| --- | --- |
| `ack` | afind alias |
| `chezmoi` | Configuration application |
| `docker-compose` | doco alias |
| `ffmpeg` | Original Brewfile declaration |
| `fzf` | tmux session picker |
| `git-delta` | Git pager and interactive diff filter |
| `git-flow-avh` | Original Brewfile declaration |
| `git-lfs` | Configured LFS filters |
| `gpac` | Original Brewfile declaration |
| `mas` | Existing App Store installation phase |
| `mise` | Declared runtimes and npm tools |
| `most` | M global alias |
| `openconnect` | vpnstart helper |
| `pv` | Original Brewfile declaration |
| `python@3.14` | Bootstrap, preferences and weekly maintenance interpreter |
| `tlrc` | Current replacement for original tldr declaration |
| `tmux` | Existing tmux configuration and aliases |
| `tree` | tre helper |
| `uv` | Declared Python CLI tool provisioning |
| `vim` | Original editor and configuration |
| `yt-dlp` | Current replacement for original youtube-dl declaration |

## Removed added formula declarations

`ansible`, `ast-grep`, `automake`, `bat`, `bison`, `cloudflared`, `coreutils`, `cups`, `e2fsprogs`, `exiftool`, `eza`, `fd`, `flyctl`, `gcc`, `gdbm`, `ghcup`, `git`, `gnu-sed`, `go`, `grep`, `mysql`, `netperf`, `openvpn`, `pkgconf`, `postgresql@17`, `readline`, `ripgrep`, `telnet`, `tpm`, `transmission-cli`, `wakeonlan`, `wget`, `zoxide`

These are on-demand tools rather than fresh-install defaults. The PostgreSQL 17 replacement is no longer selected, and neither MySQL nor PostgreSQL is automatically installed. Preserve existing database exports separately if needed later. The remaining .NET 8 SDK cask was also removed; install a project-specific SDK only when needed.

The mise and uv manifests retain the captured runtime/global-tool configuration; this curation concerns the added Homebrew declarations.
