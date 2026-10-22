# Contributing to Kabuk

Thanks for helping. This guide covers getting a build running, where things live, and how to check your change: with unit tests, and by driving the app from scripts.

## Setup

You need Xcode 26 or later. The macOS 26 SDK provides the Liquid Glass APIs. The app itself still runs on macOS 14.

```sh
swift build            # debug build of everything
swift test             # KabukCore unit tests
scripts/build-app.sh   # bundles build/Kabuk.app (Info.plist, icon, kabuk-hook, signature)
open build/Kabuk.app
```

`build-app.sh` signs with the "Kabuk Code Signing" certificate when the keychain has it, and ad hoc otherwise. macOS keeps Kabuk's permissions (Files and Folders and the like) only while that certificate stays the same, so releases are always signed with it. `scripts/make-signing-cert.sh` creates it once; keep a backup of it.

There's no Xcode project. Open `Package.swift` in Xcode if you want the IDE.

## Where things live

| Path | What's there |
|---|---|
| `Sources/KabukCore/` | Logic without UI: `StatusReducer` (the one place pane status changes), `PaneNode` (split tree), parsers for git, transcripts, zsh history and `lsof`, `Pricing`, `TurnChange`, `IntegrationInstaller`. |
| `Sources/Kabuk/AppState.swift` | Central app state. Handles hook events, sessions, panes, permissions, failures, turn changes and persistence. |
| `Sources/Kabuk/UI/` | SwiftUI views: sidebar, pane container, palette, history, themes, diff sheet, the Metal background. |
| `Sources/Kabuk/Services/` | Background work: git, worktrees, ports, history, usage ledger, notifications, the demo recorder. |
| `Sources/Kabuk/Terminal/` | SwiftTerm integration, the zsh integration script, output capture. |
| `Sources/Kabuk/IPC/` | The Unix socket server that `kabuk-hook` and the shell talk to. |
| `Sources/kabuk-hook/` | The CLI that Claude Code hooks and Codex `notify` call. |
| `Tests/KabukCoreTests/` | Unit tests. |
| `scripts/` | Build, icon, debug driver, demo. |

### How an event flows

1. zsh (`kabuk.zsh`) or an agent hook sends one JSON line to `kabuk.sock`.
2. `SocketServer` decodes it into a `HookEvent`.
3. `AppState.handle` passes it through `StatusReducer.reduce` to get the pane's new `PaneRuntime`.
4. SwiftUI redraws.

To add a new kind of event, start with a test in `StatusReducerTests`.

## Guidelines

- **Logic goes in KabukCore with a test.** If something can be decided without a window, put it there and cover it in `Tests/KabukCoreTests`.
- **Match the surrounding code.** Use small types, plain names, and comments that explain *why*, not *what*.
- **The interface is English.** Keep strings short and use sentence case.
- **Kabuk must never break an agent.** `kabuk-hook` always exits 0 and does nothing outside a Kabuk pane. If the app isn't running or doesn't answer, the agent carries on as usual.
- **Never block the main thread on a subprocess.** Use `Shell.run` from a background queue, the way `GitMonitor` and `PortMonitor` do.
- **Build without warnings.** `swift build` and `scripts/build-app.sh` should be warning-free.

## Driving the app from scripts

Launch with `KABUK_DEBUG_DIR` set and Kabuk listens for distributed notifications. A debug run doesn't bring itself to the front.

```sh
KABUK_DEBUG_DIR=/tmp/kabuk-debug build/Kabuk.app/Contents/MacOS/Kabuk &
swift scripts/kabuk-debug.swift type 'ls\r'      # type into the focused pane
swift scripts/kabuk-debug.swift action splitRight:
swift scripts/kabuk-debug.swift snapshot         # writes /tmp/kabuk-debug/snapshot.png
swift scripts/kabuk-debug.swift dump             # focus, sessions, pane status → focus.txt
```

The full list of commands is at the top of `Sources/Kabuk/DebugHooks.swift`. It includes:
- `answer allow|deny|always|ask`, `showdiff [file]`, `failure`, `ask claude|codex`
- `findquery`, `theme <id>`, `keys`, `key`, `select`, `opacity`, `caption`, `close`

`snapshot` uses `cacheDisplay`, so it can't draw anything Metal or Core Animation puts on screen: the glass blur, the Metal background, the terminal text (SwiftTerm's Metal renderer) and the looping status animations. Check those by eye.

**Keep your own Kabuk safe:** set `KABUK_SUPPORT_DIR=/some/folder` too. The debug copy then gets its own state, socket and history, and the Kabuk you're working in stays untouched.

## Recording the demo

`scripts/demo/` plays and records the demo video. It needs no API calls:

```sh
scripts/demo/setup.sh            # ~/KabukDemo: a small git repo, seeded history
scripts/demo/run-demo.sh --dry   # play it, saving a snapshot after each scene to ~/KabukDemo/debug
scripts/demo/run-demo.sh         # record to ~/Movies/Kabuk-Demo.mp4
scripts/demo/cleanup.sh          # remove ~/KabukDemo and its worktrees
```

How the demo is set up:
- **Isolation:** the demo copy runs with `KABUK_DEMO=1` and its own support folder. It records its own window with ScreenCaptureKit, so the first run asks for Screen Recording permission.
- **Permission resets:** the build is signed ad hoc, so every rebuild resets that permission.
- **Simulated agents:** `scripts/demo/bin/claude`, `codex` and `npm` stand in for the real tools. They call the real `kabuk-hook`, so the whole path is exercised.
- **Scenes:** edit `run-demo.sh` to change scenes or captions.

## Pull requests

- Keep each PR to one change and explain why in the description.
- Before you open it, run `swift test` and `scripts/build-app.sh`. Try your change in the app.
- For a visible change, add a screenshot or short clip.
- If you change something the README describes, update the README in the same PR.
- Add a line for anything a user would notice to `CHANGELOG.md` under **Unreleased**, in the right group (Added, Changed, Fixed, Removed). Write it for users: what they can now do or what no longer goes wrong.

## Releasing

Releases are cut from a clean `main`:

```sh
scripts/release.sh 0.2.0 --dry-run   # shows the CHANGELOG, README and Info.plist changes, then undoes them
scripts/release.sh 0.2.0             # releases
```

The script turns **Unreleased** into `## [0.2.0] - <today>`, rewrites README's What's new from it, sets the version in `Resources/Info.plist`, runs the tests, builds and zips the app, then commits `Release 0.2.0` and tags `v0.2.0`. After you confirm, it pushes and creates the GitHub release with that version's notes and the zip. Publishing needs the GitHub CLI signed in (`gh auth login`).

Installed copies of Kabuk find the release through the GitHub API, so keep its shape: the tag is `vX.Y.Z`, the release is neither a draft nor a prerelease, its notes are the CHANGELOG section (shown in the app's update sheet), and it carries `Kabuk-X.Y.Z.zip` with `Kabuk.app` at the top level. The app is built with `CHANGELOG.md` inside it for What's New. To try the update flow without publishing, point a debug copy at a local release list with `KABUK_UPDATE_FEED=file:///path/to/releases.json`.

## Reporting bugs

Please include:
- your macOS version
- your shell, and whether you use the Claude/Codex integration
- the steps that reproduce the bug

`swift scripts/kabuk-debug.swift dump` output from a debug run helps with focus and status bugs.
