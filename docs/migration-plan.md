# Approved implementation brief

Prepare `chezmoi-macos27` in a separate worktree for a fresh macOS 27 installation on this Apple Silicon Mac. Preserve existing working changes and the live machine. All migration changes remain uncommitted until user review.

- Retain functioning current apps and explicitly requested CLI tools; exclude Fish, Ghostty, Cursor, Alfred and stale receipts. The user subsequently selected Sol instead of Raycast and CotEditor instead of TextMate, Sublime Text and Typora.
- Capture current configuration with chezmoi, including shell/editors/window manager/agent tools/local utilities, and broad selected macOS settings plus a manual restore inventory.
- Consolidate Node/Python/Ruby into mise with supported global defaults. Respect project version files; document legacy exceptions and private global tools.
- Keep credentials in separately restored private files. Do not capture account databases, app histories, caches or private keys.
- Use resumable, explicit provisioning phases; ordinary chezmoi apply manages files only.
- Provide weekly declared-package app/CLI updates, interactive installer exclusions, failure logging, overlap prevention and seven-day cleanup.
- Validate with behavioral tests and an isolated destination; actual macOS 27 acceptance remains a post-install step.
- No commits, push, merge or live deployment.

The user subsequently excluded 29 occasional-use casks from fresh installation; see optional-apps.md. Their settings can remain available for later use. User edits to CLI entries in Brewfile take precedence over the original receipt-based inventory.

The user subsequently requested that added CLI formulae be limited to direct bootstrap/configuration dependencies; see cli-dependencies.md. Original formula declarations remain through current names. Database servers and the remaining .NET SDK are on demand.
