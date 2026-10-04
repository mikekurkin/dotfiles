# Migration report — 2026-10-04

The migration was prepared on `chezmoi-macos27` at `~/dotfiles-chezmoi`, based on `aa26a95`, and approved for a local commit after user review. The original working files were preserved separately, and the original checkout remains active.

## Restore inventory

- 21 declared formulae, 54 casks and 12 App Store applications. The [application table](applications.md) assigns restore dispositions to 136 discovered bundles plus the newly selected Sol and CotEditor, including vendor/parent installers.
- 41 pinned Zsh/Vim/tmux plugin repositories. Shell/Vim startup no longer downloads dependencies. A locally vendored fasd script preserves existing navigation; its upstream is unmaintained.
- Zsh, Git, Vim, tmux, AeroSpace, five-rule live Karabiner profile, VS Code, Zed, iTerm, IINA, optional SwiftBar scripts, Punctual layout, agent settings/custom skills and local CAD utilities are captured.
- AeroSpace assignments: calendars `C`, 3D/CAD `3`, images/photos `2`, Activity Monitor `1`, VPN clients `V`, messaging apps `T`. Rules include optional installed apps without adding them to the fresh-install manifest. Zoom and FaceTime retain `Z`.
- 100 selected macOS preference keys across 11 domains, including keyboard shortcuts and Finder list-view defaults (Date Modified, newest first, Calculate all sizes). Broad key/system inventories are recorded without copying mutable OS preference databases.
- Fish, Ghostty, Cursor, Alfred, Raycast, TextMate, Sublime Text and Typora are intentionally absent from installation and restoration. Sol and CotEditor are selected replacements. The [optional applications](optional-apps.md) are excluded from fresh installation and updates; captured settings are retained for later use. Obsolete AeroSpace rules for retired editors/terminals were removed.

## Sanity corrections

- Replaced hardcoded Node 20 paths in the Claude wrapper and tmux status command with portable executable resolution. Node/Python/Ruby defaults are declared through mise; project version files remain authoritative.
- Replaced the unavailable `tldr` formula with `tlrc` and `youtube-dl` with `yt-dlp`. Removed obsolete core/bundle/services/font/autoupdate taps. Custom tap declarations remain explicit.
- Restored both original quarantine settings at the user's request. Removed numeric Linux distribution comparison, case-dependent Brewfile linking and the 802-line historical defaults script; selected current preferences are declared separately.
- Corrected the macOS `ls --color` alias to `ls -G`, guarded optional integrations and private environment loading, and corrected VPN stdin/quoting behavior.
- Removed obsolete VS Code Python linting/formatting settings and added modern Flake8/autopep8 extension declarations. Removed the unsupported import-order argument and the absent Ruby formatter selection; project-specific restoration steps are documented.
- Vim's missing native input-layout library disables that optional integration instead of pointing at an absent Intel-prefix file. Plugin installs are pinned and provisioned explicitly.
- iTerm settings are imported via the preferences API, excluding window/session identifiers, AI/account state and the stale custom preference-folder path. Nested key mappings retain their control characters.
- Weekly updates are manifest-scoped, check app bundles or installed CLI binaries, skip interactive/privileged casks, prevent overlap, rotate logs and attempt seven-day cleanup after update, upgrade or metadata-read failures. Runtime/plugin pins are updated explicitly.

## Minimal CLI selection

The user requested removal of added tools without a direct configuration/bootstrap dependency. The [dependency table](cli-dependencies.md) explains each remaining formula. Homebrew installs needed transitive dependencies; standalone development/network/database utilities are on demand. The remaining .NET 8 SDK was also removed.

## Behavior choices for review

The quarantine removal was reversed. The [behavior audit](behavior-changes.md) identifies remaining choices, including the private-file permission gate, omitted Codex trust, runtime/database version changes, editor behavior, updater scope and app-preference omissions. These should not all be described as necessary sanity corrections. The audit also records that modern Homebrew ignores the restored legacy cask option.

## Items requiring attention before a fresh installation

- Existing projects pin Node 20.2.0, Ruby 3.1.2 and Python 2.7.18. Keeping their version files does not establish buildability on macOS 27; Python 2.7 in particular needs a separate compatibility plan or project modernization.
- Neither PostgreSQL nor MySQL is installed by the minimal manifest. Preserve existing database exports; install the required server version separately if a project needs it.
- Licensed SketchUp 2025 is a manual restore, avoiding a silent upgrade to another licensed edition. Chromium is manual because its current cask is disabled. Codex desktop's deprecated receipt is not treated as its CLI installer.
- Native filesystem/network/device utilities need vendor confirmation for macOS 27 and user permission grants. Installer availability/minimum OS metadata is not proof of macOS 27 compatibility.
- Obsidian vault plugins/settings, browser profiles, CAD/Resolve assets, private files and application data require separate backups/exports. Basic settings captured in Git do not replace those backups.
- Optional Zed extensions and project-specific editor formatter dependencies require the listed manual steps. The old global `prettier-eslint` library has no executable and is excluded from mise; restore it per project where needed. Verify `Iosevka Term SS07` is available after font installation.
- FileVault status could not be established in the sandbox. Gatekeeper currently reports enabled; recheck both after installation.
- Original credentials were not copied into the repo. Restore private VPN/SSH/cloud/npm files separately. The current `~/.secret` permission issue is handled in the new shell by skipping broadly readable files.

Manual/vendor application entries: Akko Cloud Driver, Chromium, Clean Me, CleanMyMac X, Codex, DaVinci Resolve, Dozer, FoXray, Guitar Pro 7, Hyperspace, Imaging Edge Desktop, Logi Bolt, OpenVPN Connect, PD Runner, PiPifier, Sideloadly, SketchUp, Spatial Media Metadata Injector, Speedtest, Subsee, Super Agent, T-Mazing, Telegram 2, Telegram-1, TrackWeight, Vimari, Windsurf, WireGuard, Wireless Auto Import, Xcode, Yandex Smart Home Control, YouTube+, Zenmoney, Autodesk Fusion.

## Independent review

The review found four important issues, all corrected and checked: failed preference exports now skip imports, old maintenance jobs must be confirmed unloaded before replacement, standalone CLI casks participate in weekly updates, and Flake8 receives only supported options. Regression tests reproduced the failure paths before the fixes.

Minor findings were also addressed: bootstrap prevents implicit Homebrew upgrades, cleanup runs after metadata-read failures, and the absent Ruby formatter selection was removed with explicit project restoration instructions. No live preferences or launchd jobs were changed.

All 330 original working-file hashes and the original checkout status match the saved baseline. The migration is retained on its separate branch; no push, merge or live deployment was requested.

## Validation boundaries

All 25 behavioral tests pass, including preservation of nested preferences and repeat-import avoidance. Isolated chezmoi apply twice and verify pass, along with syntax/formats, package-policy parity, private permissions and credential checks. An additional disposable-home check loads the pinned Zsh and tmux plugins successfully and confirms that mise reads project Node 20.2.0, Python 2.7.18 and Ruby 3.1.2 version files without installing them. Python tool dependency metadata resolves for Python 3.14/Apple Silicon. Verification never executes live preferences imports or maintenance registration.

This machine currently runs macOS 15.0.1. Actual macOS 27 app behavior, permission grants, legacy runtimes, driver support and preference effects remain post-install checks in [the checklist](fresh-install.md). Homebrew manifest validation does not install all declared packages.

## Sources

- [ChezMoi migration](https://www.chezmoi.io/migrating-from-another-dotfile-manager/), [Homebrew Bundle](https://docs.brew.sh/Brew-Bundle-and-Brewfile), [mise configuration](https://mise.jdx.dev/configuration.html).
- [Homebrew formula API](https://formulae.brew.sh/api/formula.json), [cask API](https://formulae.brew.sh/api/cask.json), [official AeroSpace tap](https://github.com/nikitabobko/homebrew-tap/blob/main/Casks/aerospace.rb).
- [Node release metadata](https://nodejs.org/dist/index.json), [Codex configuration reference](https://developers.openai.com/codex/config-reference/).
