# Changelog

Every release of Kabuk, newest first: what was added, changed and fixed since the version before. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/).

Changes that are on `main` but not released yet are listed under **Unreleased**. `scripts/release.sh` turns that section into the next version.

## [Unreleased]

### Added

- **Undo a turn.** The turn card has an Undo button that puts every file the agent changed back the way it was before the turn, untracked files included, and moves the branch back if the agent committed. Redo brings the changes back.
- **Review notes for the agent.** Hover a line in a turn's diff to leave a note on it. The notes go to the pane's agent as one prompt, with file, line and code, or wait until the agent's current turn ends. Diffs now show line numbers.
- **Review & Merge for worktrees.** See a worktree branch's commits and every changed file against the main checkout's branch, commit what's left, then merge, squash-merge or open a pull request. A merge that hits conflicts is rolled back. Afterwards Kabuk can remove the worktree and branch. Open it from the session's context menu, the palette, or when closing the session.
- **Subagents under their session.** When Claude starts subagents, they appear under its session in the sidebar and as chips along the bottom of its pane, with their task, time, tool count and worktree branch. Click one for a live view of its steps, and to review and merge its worktree.
- **Worktrees for editing subagents.** Claude's subagents that can edit files get their own git worktree automatically, so parallel subagents don't overwrite each other. Read-only agents such as Explore and Plan are left alone. Turn it off from the palette.
- **Claude can hand work to Codex.** The integration adds a `kabuk-delegate` skill: when you ask Claude to give a task to Codex (or another Claude), it runs `"$KABUK_HOOK" spawn codex …`, and Kabuk starts that agent in a new worktree session under Claude's, without switching away from what you're looking at.
- **Sessions started from a session sit under it.** A worktree session opened with ⌥⌘T, or spawned by an agent, appears under the session it came from in the sidebar and as a chip at the bottom of its pane.

### Changed

- Status indicators animate with Core Animation instead of SwiftUI timelines, which cuts idle CPU use.
- Terminals are drawn with SwiftTerm's Metal renderer.
- The Metal background stops drawing when nothing is happening or the window is out of sight.

### Fixed

- A worktree session joins its project even when the project was opened through a symlinked path such as /tmp.
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
