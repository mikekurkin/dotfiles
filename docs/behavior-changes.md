# Migration behavior audit — 2026-10-04

Compared with the active configuration and original working files, rather than only the old Git commit. Everything listed here concerns the `chezmoi-macos27` migration branch; the live setup remains in use.

## Quarantine restoration requested by the user

- Restored `HOMEBREW_CASK_OPTS='--no-quarantine'` in the managed `.homebrewrc`.
- Restored `com.apple.LaunchServices: LSQuarantine = false` in the explicit preferences phase.
- Bootstrap sources the declared Homebrew environment, and the weekly job receives the same cask option.

Compatibility finding: the installed Homebrew 7.0.7 code no longer implements `--no-quarantine` as an install option. Its cask configuration parser ignores this environment option, and downloads invoke quarantine handling unconditionally. Restoring the declaration preserves the requested configuration; it does not establish that modern Homebrew reproduces its historical effect. No substitute mechanism or live attribute removal was introduced. The effect of `LSQuarantine=false` on macOS 27 is also unverified.

Local evidence: `/opt/homebrew/Library/Homebrew/cmd/install.rb`, `cask/config.rb` and `cask/download.rb`. The [current official manual](https://docs.brew.sh/Manpage) likewise omits `--no-quarantine` from supported cask environment options.

## Other choices still present in the branch

These are behavioral choices or omissions, not prerequisites of replacing Dotbot with chezmoi. They remain unchanged during this audit so the user can review them explicitly.

| Area | Original/current behavior | Prepared behavior / consequence |
| --- | --- | --- |
| Private environment | Source readable `~/.secret` regardless of mode | Load only with mode 600; currently readable private configuration is skipped until permissions are changed |
| Codex trust | Nine current project/home paths marked trusted | Trust entries omitted; projects require trust again. Intro/notice state also omitted |
| Default runtimes | Node 20.19.0, Python 3.10.5, Ruby 4.0.7 in the audited shell | Node 24.21.0, Python 3.14.8, Ruby 4.0.7 via mise; project version files are retained, but default compatibility changes |
| Database installation | PostgreSQL 14 declared/installed; service stopped | Later user CLI curation removes the proposed PostgreSQL 17 replacement and MySQL; install project-required databases on demand |
| Global tool versions | Multiple old runtime-specific npm/Python installations | Selected pinned tool set via mise and uv. TypeScript 5.9.3, Yarn 1.22.22 and IPython 9.6.0 are version choices; not every old interpreter/global environment is reconstructed |
| Python linting | pyenv Flake8 path, import-order style and category severity preferences | Modern extension/bundled Flake8; import-order check removed; old F-category warning mapping not migrated. autopep8 switches away from the old pyenv path |
| Ruby editor formatter | `rebornix.ruby` selected, though absent from installed extensions | Default formatter selection removed; project-specific manual restoration required |
| Shell locale | Both `LANG` and `LC_ALL` forced to `en_US.UTF-8` | Only `LANG` is forced, permitting category-specific locale overrides |
| Shell keys | Old `[D` / `[C` word-navigation bindings; vi mode applied late | Ctrl-arrow bindings use full escape sequences; vi mode precedes the later custom/history bindings |
| Plugin lifecycle | Zplug manages shell plugins; Vim auto-installs missing plugins; tmux uses TPM | Explicit pinned provisioning; shell/Vim startup does not install missing dependencies; tmux sources declared plugins directly |
| Optional Vim layout switching | Intel-prefix library path configured | Apple Silicon path used; feature disabled if the native library is absent |
| Weekly updater coverage | Existing daily Homebrew autoupdate job | Weekly manifest-only upgrades; missing app artifacts, privileged/interactive casks, fonts/layouts and App Store apps excluded from unattended upgrades. Runtime/plugin/uv tool pins require explicit updates |
| Updater telemetry | No equivalent opt-out declared in the old environment | `HOMEBREW_NO_ANALYTICS=1` set for maintenance only |
| App restore | Existing bundle versions/receipts | Enabled casks track current releases. Deprecated/unidentified/licensed apps have manual restore dispositions; bundle presence was used as an installation signal, not proof of ongoing use |
| System preferences | Full current preference domains plus a historical defaults script | Selected keys restored automatically; Dock order, input-source selection, power settings, login items and service activation left manual. Not all historical tweaks or current preferences are captured |

The runtime manager, weekly update frequency, cleanup retention, retired-app exclusions and private credential backups were part of the approved direction. Exact runtime versions, database major version, update exclusions and other defaults above are still choices worth reviewing separately.

## App-preference omissions discovered during the audit

The earlier capture filter was broader than necessary. These omissions can change fresh-install behavior even though they were not deliberate replacement preferences:

- iTerm: `AppleWindowTabbingMode`, `DimBackgroundWindows`, `NSUserKeyEquivalents`, `OpenBookmark`, `OpenNewWindowAtStartup`, `OpenNoWindowsAtStartup`, `QuitWhenAllWindowsClosed`, `ShowBookmarkName`, `VisualIndicatorForEsc`, paste substitution settings, update-check/automatic-update preferences and AI feature/model preferences.
- IINA: `alwaysOpenInNewWindow`, `initialWindowSizePosition`, `resizeWindowTiming`, `showRemainingTime`, `togglePipByMinimizingWindow`, `trackAllFilesInRecentOpenMenu`, OpenSubtitles plugin enablement, update-check/profile-sharing settings and the selected audio-device preferences.
- iTerm window arrangements, saved session/window positions and custom preference-folder settings were also excluded. Some contain machine-specific or mutable state; their restore policy still needs explicit review rather than a claim that the configuration is complete.

Histories, credentials, private keys and account databases remain separate backups. The comparison here prints/records preference key names without exposing their private values.

## Actual corrections rather than policy replacements

Portable home/runtime paths, macOS-compatible `ls -G`, quoted VPN arguments and password-on-stdin handling, preserving existing preferences after read errors, refusing overlapping updater jobs, and keeping the original worktree intact are implementation fixes. Git identity/settings, Vim leader/keybindings, Powerlevel10k, the live Karabiner rules, Zed settings and Claude permission rules were retained. Differences from the old commit in several of those files were already present in the user's working configuration.

## Explicit app choices after this audit

The user selected Sol instead of Raycast and CotEditor instead of TextMate, Sublime Text and Typora. Their installation/update declarations and captured retired-app configurations were removed. Sol and CotEditor have no invented settings; they will be configured after trying them. Sublime Merge remains a Git client.

## Later optional-app curation

The user subsequently excluded 29 occasional-use casks, including Sublime Merge, Zed and SwiftBar, from fresh installation and weekly updates. This supersedes the earlier Sublime Merge installation choice. Captured settings remain available; SwiftBar preferences are not imported by default. See optional-apps.md. CLI declarations follow the user's edited Brewfile.
