# Changelog

Every release of Kabuk, newest first: what was added, changed and fixed since the version before. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/).

Changes that are on `main` but not released yet are listed under **Unreleased**. `scripts/release.sh` turns that section into the next version.

## [Unreleased]

### Changed

- Status indicators animate with Core Animation instead of SwiftUI timelines, which cuts idle CPU use.
- Terminals are drawn with SwiftTerm's Metal renderer.
- The Metal background stops drawing when nothing is happening or the window is out of sight.

### Fixed

- The failure chip appears even when the shell's end event reaches Kabuk after the terminal output.

## [0.1.0] - 2026-10-20

The first release.

### Added

- Agent status for Claude Code and Codex in the sidebar and on each pane: running, working, needs you, done, failed, with working time, context size and API-price cost.
- Parallel agents in git worktrees (⌥⌘T), with the worktree offered for removal when the session closes.
- Approve Claude's tool use from the sidebar or the notification: Allow, Always, Deny.
- A card listing the files an agent changed in its last turn, with a colored diff per file.
- Failed commands handed to an agent with their output (Ask Claude / Codex chip).
- Dev server ports detected and shown as clickable chips.
- Command palette (⌘K), history search (⌘R) and find in pane (⌘F).
- Seven themes plus your own JSON themes, three transparency levels, Liquid Glass on macOS 26.
- Split panes, git badges, cost tracking, notifications, a Dock badge and session restore.

[Unreleased]: https://github.com/egemenagustos/Kabuk/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/egemenagustos/Kabuk/releases/tag/v0.1.0
