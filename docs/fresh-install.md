# Fresh installation and separate backups

## Before erasing

- Preserve the reviewed source and its Git history outside this Mac. Use a standalone clone or repository backup; a linked worktree's `.git` pointer alone does not contain the repository history.
- Back up every project repository, working tree, document, media library, cloud folder not fully synchronized, local database and container volume. Export existing PostgreSQL 14/MySQL databases if needed later. Database servers are not installed by bootstrap; choose a compatible server and migration separately.
- Back up private files separately: `~/.secret`, `~/.ssh`, VPN configuration including `~/.config/openconnect.conf`, certificates, private npm registry configuration, cloud credentials and account recovery information. Verify encrypted backup access from another device.
- Restore Obsidian vaults including `.obsidian`; see [the vault inventory](obsidian-restore.md). Keep plugin credentials in the private backup.
- Back up app-specific settings/exports and data for OrbStack containers, browsers, Git clients, CAD apps, Resolve projects/LUTs, Postman workspaces, VPN clients, Dash snippets/docsets, and other apps you want to restore. The [application table](applications.md) records installer dispositions.
- Preserve licenses and the correct licensed versions of SketchUp, Fusion, Adobe tools, Guitar Pro and other commercial software. Check each vendor's macOS 27 support before restoring plugins or kernel/system extensions.
- Preserve any custom fonts not provided by the declared font casks. Confirm the configured `Iosevka Term SS07` family is available; its absence can cause silent font fallback.

## Private configuration

Restore `~/.secret` only after reviewing its contents, then `chmod 600 ~/.secret`. The shell skips this file if its permissions are broader. Restore SSH directories as mode 700 and private keys/configuration as mode 600. Credentials are never created from the source repository.

The VPN helpers require the separately restored environment variables and configuration. Private npm tool names/versions are listed in `private-npm-tools.json`; install only after restoring registry authentication. Agent sign-in and MCP authorization are separate from their non-secret configuration.

## Manual system setup

- Restore the computer name `Wellick`, login items, and intended service startup policy from `system-inventory.json`. The captured Homebrew services were stopped; bootstrap does not enable database or VPN daemons.
- Restore input sources and selection through System Settings. The custom Punctual keyboard layout is captured; log out before selecting it. Verify the Birman layout and any additional layouts listed in the inventory.
- Restore Dock application order from the inventory and Finder sidebar favourites manually. Application bookmarks and machine-specific UUIDs are not transplanted.
- Grant Accessibility/Input Monitoring to Karabiner, AeroSpace, Sol and relevant utilities. Restore screen-recording/full-disk access and network/system-extension approvals as required by the apps. Permission databases are not copied.
- Configure FileVault, backups, account access, network profiles, power settings and OS updates through System Settings. FileVault status could not be verified in the sandbox; do not assume it was enabled.
- Restore AC display/sleep preferences from the inventory if still desired. Bootstrap does not execute the old privileged power-settings script.
- Install manual/vendor applications from their vendors; select compatible licensed editions. Chromium's disabled cask is not replaced automatically with a different browser. Codex desktop has a deprecated cask; install its current vendor distribution separately from the CLI.
- Install [optional applications](optional-apps.md) only when needed. If installing Zed later, use the retained extension list in `~/.config/dotfiles/zed-extensions.txt`.
- Ruby formatting: the stale `rebornix.ruby` default was removed because that extension is no longer installed. For each Ruby project, restore its Gemfile/lockfile and formatter configuration, run its declared formatter through Bundler, then choose the corresponding installed VS Code formatter via **Format Document With → Configure Default Formatter**. No global formatter is imposed on legacy Ruby projects.
- Python linting uses the modern Flake8 extension's bundled tool with the supported line-length option. To restore import-order linting, add `flake8-import-order` to the project's development dependencies and configure the extension to use that environment before adding `--import-order-style=pep8`.
- `prettier-eslint@16.3.0` was a globally installed library with no executable. Restore it as a project dependency where required; the VS Code Prettier ESLint extension is retained. It is not a mise CLI tool.

## Finder defaults

The preferences phase sets list view as Finder's default, sorts by Date Modified (newest first), and enables Calculate all sizes. Both list-view preference formats are captured with the current column layout. Nested preference dictionaries are merged so unrelated settings survive; no folder metadata is removed.

These defaults apply to folders without their own saved view. Restored folders can carry overrides in `.DS_Store`; a global preference cannot guarantee the same view for every such folder. For exceptions, select the parent folder, use Command-J to enable Always open in list view and Browse in list view, and use Use as Defaults. Clear the corresponding Always open in / Browse in overrides on subfolders that still differ, as described in [Apple's Finder view guide](https://support.apple.com/en-gb/guide/mac-help/mchldaafb302/mac). Verify Date Modified order and Calculate all sizes on macOS 27 after logging back in.

## Newly selected apps

Sol replaces Raycast. Grant the permissions needed for the Sol features you choose, set its launcher hotkey, and enable launch at login if desired. Configure and test it before capturing its settings; no Raycast configuration is imported into Sol.

CotEditor replaces TextMate, Sublime Text and Typora. Its Homebrew cask supplies the `cot` launcher. Set preferred fonts, shortcuts and file associations in CotEditor/Finder after trying it, then capture selected settings. No editor preferences are invented or automatically translated. The old Sublime/TextMate AeroSpace rules and obsolete iTerm editor identifier were removed; iTerm's existing best-editor action is retained. Sublime Merge is now an optional application and is excluded from fresh installation.

## Post-install acceptance

- Check macOS version/architecture, Homebrew paths, and `brew bundle check --file=Brewfile` plus the separate App Store manifest after sign-in.
- In a new login terminal, check `command -v node python ruby claude` and `mise current`. Verify defaults and representative project version files. Node 20.2.0, Ruby 3.1.2 and Python 2.7 projects remain legacy exceptions; their buildability on macOS 27 is not established.
- Confirm Git identity, aliases, delta paging, LFS and commit template. Open Vim, tmux, VS Code and CotEditor; check fonts, plugins, keybindings and expected formatting.
- Check all five active Karabiner rules and AeroSpace workspace assignments. Inspect app interactions for binding conflicts and confirm window-management permissions.
- Check iTerm profiles/keys and IINA controls after import. Verify keyboard shortcuts, input sources, Finder/Dock/appearance and screenshot directory. Preference storage success alone does not prove an old key still affects macOS 27.
- Confirm `launchctl print gui/$(id -u)/net.kurkin.dotfiles.maintenance` succeeds and the old daily autoupdate job is absent. Run the maintenance script once interactively, inspect its log and verify interactive casks are skipped.
- Local CAD utilities are optional: FreeCAD is not installed by bootstrap. Check them only after manually installing compatible FreeCAD/SketchUp and restoring licensing. Verify the seed/template models and run a disposable model conversion before using production files.
- Repeat configuration application and confirm `chezmoi --source "$PWD" verify` succeeds. Review app-written changes with `diff` rather than overwriting them blindly.
