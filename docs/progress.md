# Migration execution ledger

Plan: approved conversation plan, revised to exclude Fish, Ghostty, Cursor, Alfred.
Constraints: local commit authorized after user review; no push, merge, or live-machine deployment.

- Worktree: /Users/mk/dotfiles-chezmoi, branch chezmoi-macos27, base aa26a95.
- Original working-files backup: /private/tmp/dotfiles-migration-20261004/original-working-files.tar.gz.
- Original source hashes and status recorded separately for final comparison.
- Ruling: use an isolated worktree and retain progress records uncommitted; user review overrides skill commit/cleanup steps.
- Ruling: existing project runtime files remain untouched; unsupported runtimes are documented rather than silently upgraded.
- Pre-flight: bootstrap, maintenance, and config capture share the package manifest; tests must verify manifest parity.

- Configuration capture: working shell/editor/window manager/agent preferences plus selected system settings and local CAD sources imported; retired tools excluded.
- Workflow tests: 23 tests cover scoping, failed/overlapping jobs, repeatable bootstrap, preference merging, plugin paths, JSONC and secret scans.
- Isolated chezmoi apply twice and verify passed with checksum-verified chezmoi 2.73.0.
- Python tool metadata: graphifyy 0.8.26 and IPython 9.6.0 resolve on Python 3.14 / Apple Silicon (49 dependencies); no tool installation performed.
- Ruling: keep licensed SketchUp and disabled Chromium as manual restore entries; matching a bundle name does not justify switching editions.
- Ruling: preserve fasd as a vendored MIT script to keep current navigation, rather than changing aliases to zoxide.

- Independent review: four important and three minor findings resolved; regression cases observed failing before fixes and passing afterward.
- Pinned plugin smoke check: all source revisions match the lock manifest; Zsh and an isolated tmux server start cleanly. No live sessions touched.
- Mise discovery: all three representative project version files take precedence; no legacy runtimes installed.
- Final verification: 23 tests, complete isolated renderer, format/secret/permission checks and package parity pass.
- Original comparison: 330 hashes unchanged; original Git status matches; original home symlinks retained.
- Branch finishing ruling: keep worktree and branch as-is, with no commits, staging, push or merge, per user instruction. New files are marked intent-to-add only to make them visible in the unstaged review diff.

- User review correction: restored both quarantine declarations, including bootstrap/job environment; audited other policy changes and app-preference omissions in behavior-changes.md. Other choices were not changed by this follow-up.

- Explicit app replacements: Sol for Raycast; CotEditor for TextMate/Sublime Text/Typora. Removed captured retired-app preferences and stale editor references; retained Sublime Merge. Manifest now has 84 casks. Live apps unchanged; no commits.

- User curation: excluded 29 occasional-use casks; retained versioned dotnet-sdk@8 and primary telegram. Synchronized 12 CLI removals from user edits and removed unused henryaj tap. Current manifest: 54 formulae / 55 casks. Optional configurations retained; SwiftBar preference import disabled by default.

- Minimal CLI request: removed 33 added formula declarations and the remaining dotnet-sdk@8 cask; retained original tools and direct configuration/bootstrap dependencies. Current selection: 21 formulae / 54 casks; manifests synchronized.

- AeroSpace review: calendars → C, 3D/CAD → 3, images/photos → 2, Activity Monitor → 1, installed VPN clients → V, messaging apps → T. Corrected Photos capitalization and Telegram bundle IDs; used Fusion's main app ID. Optional-app rules do not add installation dependencies. Existing shortcuts and conferencing assignments retained; no live reload or commits.

- Finder review: captured list-view defaults in both observed formats, Date Modified newest first and Calculate all sizes, retaining the current column layout. Fixed preference restoration to merge nested dictionaries; two regression checks reproduced lost settings/redundant imports before the fix and pass afterward. 25 behavioral tests now pass. Saved per-folder overrides are documented for fresh-install acceptance; no live preference imports, folder-metadata deletion or commits.

- User approved a local commit after review. README rewritten as a version-independent setup guide with installation, optional phases, configuration updates, verification and maintenance instructions. Historical review-only constraints above are superseded for the commit; the separate branch/worktree and live setup remain in place.
