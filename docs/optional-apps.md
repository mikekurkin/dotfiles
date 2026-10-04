# Applications excluded from fresh installation

The user excluded 29 occasional-use casks; the later CLI-minimization request also removes the versioned .NET 8 SDK. They are absent from `Brewfile` and the weekly-update package policy. Install individual apps manually later if needed. Existing captured settings are retained for occasional use; SwiftBar preferences are kept under `~/.config/dotfiles/optional-app-preferences` and are not imported by the default preferences phase.

| Cask | Install policy |
| --- | --- |
| `adguard` | On demand only |
| `adguard-vpn` | On demand only |
| `amneziavpn` | On demand only |
| `bitwarden` | On demand only |
| `dbeaver-community` | On demand only |
| `disk-drill` | On demand only |
| `dotnet-sdk` | On demand only |
| `dotnet-sdk@8` | Project dependency; on demand only |
| `epic-games` | On demand only |
| `figma` | On demand only |
| `freecad` | On demand only |
| `garmin-express` | On demand only |
| `gitkraken` | On demand only |
| `google-earth-pro` | On demand only |
| `helium-browser` | On demand only |
| `hex-fiend` | On demand only |
| `kindavim` | On demand only |
| `mullvad-vpn` | On demand only |
| `obsidian` | On demand only |
| `omnigraffle` | On demand only |
| `outline` | On demand only |
| `passepartout` | On demand only |
| `pdf-expert` | On demand only |
| `postman` | On demand only |
| `sublime-merge` | On demand only |
| `swiftbar` | On demand only |
| `telegram-desktop` | On demand only |
| `transcribe` | On demand only |
| `wifi-explorer` | On demand only |
| `zed` | On demand only |

The user wrote `hex-friend`; this refers to the `hex-fiend` cask. The later CLI-minimization request also removed `dotnet-sdk@8`; no .NET SDK is installed by bootstrap. The main `telegram` cask remains; the separate `telegram-desktop` cask is excluded.

Zed settings and its extension list remain available for a later manual installation. Local CAD helpers remain available, but FreeCAD must be installed on demand before using conversions. Obsidian vault/settings backups are retained separately.
