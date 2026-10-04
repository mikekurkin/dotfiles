# macOS dotfiles

Declarative setup for macOS on Apple Silicon. Chezmoi manages dotfiles, Homebrew Bundle installs apps and CLI tools, and mise manages language runtimes and global development tools.

## Install

1. Back up documents, projects, databases, app data, licenses and private credentials separately. Use the [restore checklist](docs/fresh-install.md) for manual setup and account restoration.
2. Install Apple's Command Line Tools:

   ```sh
   xcode-select --install
   ```

3. Install [Homebrew](https://brew.sh), then clone this repository or restore a standalone checkout from your backup. Check out the branch containing the setup you want to install and change into that directory.
4. Review the [Brewfile](Brewfile), [App Store apps](Brewfile.mas) and [optional apps](docs/optional-apps.md). Preview the installation phases:

   ```sh
   ./install --plan
   ```

5. Install packages, apply dotfiles, install runtimes and plugins, and configure editor extensions:

   ```sh
   ./install --apply packages configuration runtimes plugins editors
   ```

6. Close iTerm2 and IINA. From Apple's Terminal, apply macOS and app preferences and register weekly maintenance:

   ```sh
   ./install --apply preferences maintenance
   ```

7. Log out and back in. Restore private configuration, sign into apps, grant the permissions they require, and complete the checks in the [restore checklist](docs/fresh-install.md).

Phases can be rerun individually. If a phase fails, resolve the reported problem and rerun it. Package installation preserves already installed package versions.

## Optional phases

After signing into the App Store:

```sh
./install --apply app-store
```

After setting up agent accounts:

```sh
./install --apply agents
```

Install vendor-distributed and licensed apps separately using the [application inventory](docs/applications.md). Keep private files outside Git; restore `~/.secret` with permissions restricted to its owner:

```sh
chmod 600 ~/.secret
```

## Update dotfiles

Run these commands from the repository directory:

```sh
chezmoi --source "$PWD" diff
chezmoi --source "$PWD" apply
```

To capture a change to a managed file, re-add it, review the source diff, then commit:

```sh
chezmoi --source "$PWD" re-add ~/.config/karabiner/karabiner.json
git diff
```

Edit macOS and app preferences under `home/dot_config/dotfiles/`, then rerun the `configuration` and `preferences` phases. Ordinary chezmoi application only updates files; package installation and preference imports use their own phases.

Edit the Brewfile and `home/dot_config/dotfiles/packages.json` together to keep installation and maintenance selections aligned. Runtime selections are in `home/dot_config/mise/config.toml`; plugin revisions are in `plugins.lock.json`.

## Validate

Install the verification tools if needed:

```sh
brew install chezmoi python
```

From the repository directory:

```sh
/opt/homebrew/bin/python3 scripts/verify.py --chezmoi /opt/homebrew/bin/chezmoi
```

Verification runs behavioral tests, checks package-manifest consistency, scans for credentials, and applies the configuration twice to a temporary home. It also checks rendered formats, shell startup and private-file permissions. It does not change the live setup.

## Maintenance

The weekly job runs Sunday at 10:00 local time. It updates declared packages that are already installed and skips installers requiring interaction. Downloads older than seven days are cleaned up after update attempts.

To run maintenance manually:

```sh
python3 ~/.local/share/dotfiles/maintenance.py
```

Logs are stored in `~/.local/state/dotfiles/maintenance.log`. Per-package update rules are in `~/.config/dotfiles/packages.json`. Update runtime and plugin pins by editing their manifests and rerunning the corresponding installation phases.
