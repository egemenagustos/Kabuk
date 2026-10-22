import AppKit
import KabukCore
import SwiftUI

/// Development aid, inactive unless Kabuk is started with KABUK_DEBUG_DIR set.
/// Other processes can then post distributed notifications to drive the app:
///   dev.kabuk.snapshot          writes <dir>/snapshot.png of the window
///   dev.kabuk.type  (object)    types the text into the focused terminal
///   dev.kabuk.action (object)   runs a menu action by selector name, e.g. "splitRight:"
///   dev.kabuk.findquery (object) sets the find bar's query
///   dev.kabuk.theme (object)     switches to the theme with that id
///   dev.kabuk.answer (object)   answers the first held permission request: allow, deny, always, ask
///   dev.kabuk.showdiff (object) opens the diff of that file (or the first) in any turn summary
///   dev.kabuk.note (object)     leaves that note on the first changed line of the open diff; "send" sends the notes
///   dev.kabuk.subagent (object) opens the live view of the first subagent with that id prefix (any when empty)
///   dev.kabuk.review (object)   "open" shows the first worktree session's review; "merge" or "squash" merges it
///                               and writes <dir>/review.txt
///   dev.kabuk.undo (object)     "undo" or "redo" for the first pane with a turn summary, without asking
///   dev.kabuk.update (object)   "check" checks now, "whatsnew" shows the notes, "install" or "quit-install" installs
///                               the found update, "quit" quits; every command writes <dir>/update.txt with the update state
///   dev.kabuk.failure           writes <dir>/failure.txt: each pane's captured failure and its prompt
///   dev.kabuk.radar (object)    writes <dir>/radar.txt: every session's overlaps with parallel checkouts;
///                               "tell" first tells the first such session's agent about its first overlap,
///                               "show" opens that session's overlap details, "hide" closes them
///   dev.kabuk.ask (object)      asks claude or codex about the first captured failure
///   dev.kabuk.skills            scans the focused pane's skills and writes them to <dir>/skills.txt
///   dev.kabuk.insertskill (object) types the focused agent's skill with that invocation at its prompt
///   dev.kabuk.skillpicker       opens the focused agent pane's skill picker
///   dev.kabuk.screen            writes <dir>/screen.txt: the focused terminal's visible text, for what
///                               `snapshot` can't draw
///   dev.kabuk.dump              writes <dir>/focus.txt: the focused pane and the first responder
/// For the demo video:
///   dev.kabuk.caption (object)  shows "Title|⌘ K" in the caption strip; empty hides it
///   dev.kabuk.keys (object)     types like a person into whatever has focus: terminal, palette, search
///   dev.kabuk.key (object)      presses return, escape, up, down or ctrl-c
///   dev.kabuk.close             closes whatever overlay is open: palette, history, themes, diff, find
///   dev.kabuk.select (object)   selects the nth session (0-based)
///   dev.kabuk.opacity (object)  sets the transparency, e.g. 0.4
///   dev.kabuk.project (object)  opens that folder as the only project
///   dev.kabuk.record (object)   "start <path>" or "stop"; writes <dir>/record.txt when done
///   dev.kabuk.recpermission     writes <dir>/permission.txt, asking for Screen Recording if needed
@MainActor
enum DebugHooks {
    private static let recorder = DemoRecorder()

    static func install(window: NSWindow, target: AppDelegate, state: AppState) {
        guard let dir = ProcessInfo.processInfo.environment["KABUK_DEBUG_DIR"] else { return }
        let center = DistributedNotificationCenter.default()
        let output = { (name: String, text: String) in
            try? text.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        center.addObserver(forName: .init("dev.kabuk.caption"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                let caption = (note.object as? String).flatMap(DemoCaption.init)
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { state.demoCaption = caption }
            }
        }
        center.addObserver(forName: .init("dev.kabuk.keys"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let text = note.object as? String else { return }
                typeSlowly(Array(text), into: window)
            }
        }
        center.addObserver(forName: .init("dev.kabuk.key"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if let name = note.object as? String { press(name, in: window) }
            }
        }
        center.addObserver(forName: .init("dev.kabuk.close"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if state.paletteVisible { state.togglePalette() }
                if state.historyVisible { state.toggleHistory() }
                if state.themeGalleryVisible { state.toggleThemeGallery() }
                if state.diffRequest != nil { withAnimation(.easeOut(duration: 0.2)) { state.diffRequest = nil } }
                if state.worktreeReview != nil { state.closeWorktreeReview() }
                if state.subagentDetail != nil { state.closeSubagentDetail() }
                if state.updateSheet != nil { state.closeUpdateSheet() }
                if state.findPane != nil { state.toggleFind() }
            }
        }
        center.addObserver(forName: .init("dev.kabuk.update"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                switch note.object as? String {
                case "check": state.checkForUpdates(manual: true)
                case "whatsnew": state.showWhatsNew()
                case "install": state.installUpdate(restart: true)
                case "quit-install": state.installUpdate(restart: false)
                case "quit": NSApp.terminate(nil)
                default: break
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    output("update.txt", """
                    current: \(Updater.currentVersion?.description ?? "-")
                    available: \(state.availableUpdate.map { "\($0.version) \($0.download?.absoluteString ?? "no zip")" } ?? "-")
                    notes: \(state.availableUpdate?.notes.map(\.id).joined(separator: ",") ?? "-")
                    progress: \(state.updateProgress)
                    sheet: \(state.updateSheet.map { "\($0)" } ?? "-")
                    problem: \(state.updateInstallProblem ?? "-")
                    """)
                }
            }
        }
        center.addObserver(forName: .init("dev.kabuk.select"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if let index = (note.object as? String).flatMap(Int.init) { state.selectSession(at: index) }
            }
        }
        center.addObserver(forName: .init("dev.kabuk.opacity"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let value = (note.object as? String).flatMap(Double.init) else { return }
                withAnimation(.easeInOut(duration: 0.5)) { state.opacity = value }
            }
        }
        center.addObserver(forName: .init("dev.kabuk.project"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let path = note.object as? String else { return }
                let others = state.projects.filter { $0.path != path }.map(\.id)
                state.openProject(URL(fileURLWithPath: path))
                others.forEach(state.removeProject)
            }
        }
        center.addObserver(forName: .init("dev.kabuk.recpermission"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let granted = DemoRecorder.hasPermission
                if !granted { DemoRecorder.requestPermission() }
                output("permission.txt", granted ? "granted" : "denied")
            }
        }
        center.addObserver(forName: .init("dev.kabuk.record"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                let command = (note.object as? String ?? "").split(separator: " ", maxSplits: 1).map(String.init)
                Task { @MainActor in
                    do {
                        if command.first == "start", command.count == 2 {
                            try await recorder.start(window: window, to: URL(fileURLWithPath: (command[1] as NSString).expandingTildeInPath))
                            output("record.txt", "recording")
                        } else {
                            try await recorder.stop()
                            output("record.txt", "done")
                        }
                    } catch {
                        output("record.txt", "error: \(error.localizedDescription)")
                    }
                }
            }
        }
        center.addObserver(forName: .init("dev.kabuk.snapshot"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard let view = window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = URL(fileURLWithPath: dir).appendingPathComponent("snapshot.png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
        center.addObserver(forName: .init("dev.kabuk.type"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let text = note.object as? String,
                      let terminal = window.firstResponder as? KabukTerminalView else { return }
                terminal.send(source: terminal, data: ArraySlice(Array(text.utf8)))
            }
        }
        center.addObserver(forName: .init("dev.kabuk.findquery"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                state.findQuery = note.object as? String ?? ""
                state.updateFind()
            }
        }
        center.addObserver(forName: .init("dev.kabuk.theme"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated { state.themeID = note.object as? String ?? state.themeID }
        }
        center.addObserver(forName: .init("dev.kabuk.answer"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let decision = (note.object as? String).flatMap(PermissionDecision.init(rawValue:)),
                      let request = state.runtimes.values.compactMap(\.permission).first else { return }
                state.answerPermission(request.id, decision)
            }
        }
        center.addObserver(forName: .init("dev.kabuk.showdiff"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                let name = note.object as? String
                for (pane, change) in state.turnChanges {
                    guard let file = change.files.first(where: { name == nil || $0.path == name }) else { continue }
                    state.showDiff(file, of: pane)
                    return
                }
            }
        }
        center.addObserver(forName: .init("dev.kabuk.note"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let request = state.diffRequest, let pane = request.paneID, let text = note.object as? String else { return }
                if text == "send" {
                    state.sendComments(for: pane)
                    return
                }
                Task {
                    let lines = await Task.detached { TurnTracker.diff(request.file, in: request.change) }.value
                    guard let line = lines.first(where: { $0.kind == .add || $0.kind == .remove }) else { return }
                    state.addComment(DiffComment(path: request.file.path, diffLine: line, note: text), for: pane)
                }
            }
        }
        center.addObserver(forName: .init("dev.kabuk.subagent"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                let prefix = note.object as? String ?? ""
                for (pane, runtime) in state.runtimes {
                    if let subagent = runtime.subagents.first(where: { $0.id.hasPrefix(prefix) }) {
                        state.showSubagent(subagent.id, in: pane)
                        return
                    }
                }
            }
        }
        center.addObserver(forName: .init("dev.kabuk.review"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let session = state.allSessions.first(where: { $0.worktree != nil }), let info = session.worktree else { return }
                let action = note.object as? String ?? "open"
                if action == "open" {
                    state.reviewWorktree(of: session.id)
                    return
                }
                DispatchQueue.global().async {
                    let text: String
                    switch Worktrees.summary(info) {
                    case .failure(let failure): text = "summary failed: \(failure.localizedDescription)"
                    case .success(let summary):
                        text = Worktrees.merge(info, summary: summary, squash: action == "squash")?.localizedDescription ?? "merged"
                    }
                    output("review.txt", text)
                }
            }
        }
        center.addObserver(forName: .init("dev.kabuk.undo"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let pane = state.turnChanges.keys.first else { return }
                if note.object as? String == "redo" { state.redoTurn(pane) } else { state.undoTurn(pane, confirm: false) }
            }
        }
        center.addObserver(forName: .init("dev.kabuk.failure"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let text = state.failures.map { "pane \($0.key.uuidString.prefix(8))\n\($0.value.prompt)" }.joined(separator: "\n---\n")
                try? text.write(to: URL(fileURLWithPath: dir).appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
        }
        center.addObserver(forName: .init("dev.kabuk.radar"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                let found = state.allSessions.map { ($0, state.overlaps(of: $0)) }.filter { !$0.1.isEmpty }
                switch (note.object as? String, found.first) {
                case ("tell", let (session, list)?): state.tellAgent(about: list[0], in: session.id)
                case ("show", let (session, _)?): state.overlapDetail = session.id
                case ("hide", _): state.overlapDetail = nil
                default: break
                }
                let text = found.map { session, list in
                    "\(session.title) [\(session.worktree?.branch ?? "main checkout")]\n" + list.map { overlap in
                        "  vs \(overlap.otherBranch): " + overlap.files.map {
                            "\($0.path)\($0.conflict ? " CONFLICT" : "") \(Overlaps.describe($0.theirLines))"
                        }.joined(separator: "; ")
                    }.joined(separator: "\n")
                }.joined(separator: "\n")
                output("radar.txt", text.isEmpty ? "no overlaps\n" : text + "\n")
            }
        }
        center.addObserver(forName: .init("dev.kabuk.ask"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let agent = (note.object as? String).flatMap(AgentKind.init(rawValue:)),
                      let pane = state.failures.keys.first else { return }
                state.askAgent(about: pane, agent: agent)
            }
        }
        center.addObserver(forName: .init("dev.kabuk.skills"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard let pane = state.selectedSession?.focusedPane else { return }
                state.refreshSkills(for: pane)
                // The scan runs in the background; give it a moment before reading the cache.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let text = state.skills(for: pane).map { "\($0.insertion)\t\($0.scopeLabel)\t\($0.path)" }.joined(separator: "\n")
                    output("skills.txt", text + "\n")
                }
            }
        }
        center.addObserver(forName: .init("dev.kabuk.insertskill"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let pane = state.selectedSession?.focusedPane, let invocation = note.object as? String,
                      let skill = state.skills(for: pane).first(where: { $0.invocation == invocation }) else { return }
                state.insertSkill(skill, into: pane)
            }
        }
        center.addObserver(forName: .init("dev.kabuk.skillpicker"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { state.skillPickerPane = state.selectedSession?.focusedPane }
        }
        center.addObserver(forName: .init("dev.kabuk.screen"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard let pane = state.selectedSession?.focusedPane, let view = state.terminals.views[pane] else { return }
                let lines = String(decoding: view.getBufferAsData(), as: UTF8.self).components(separatedBy: "\n")
                output("screen.txt", lines.suffix(view.terminalDimensions.rows).joined(separator: "\n") + "\n")
            }
        }
        center.addObserver(forName: .init("dev.kabuk.dump"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let responder = (window.firstResponder as? KabukTerminalView)?.paneID.uuidString ?? String(describing: window.firstResponder)
                var text = "focused=\(state.selectedSession?.focusedPane.uuidString ?? "-")\nresponder=\(responder)\n"
                for session in state.allSessions {
                    let mark = session.id == state.selectedSessionID ? "*" : " "
                    text += "\(mark) \(session.title)\n"
                    for pane in session.root.panes {
                        let r = state.runtime(pane)
                        text += "    \(pane.id.uuidString.prefix(8)) \(r.status) permission=\(r.permission.map { "\($0.tool): \($0.detail)" } ?? "-") ports=\(r.ports)\n"
                        for sub in r.subagents {
                            text += "      subagent \(sub.type) '\(sub.title)' \(sub.state) tools=\(sub.toolCount) last=\(sub.lastTool ?? "-") branch=\(sub.branch ?? "-") transcript=\(sub.transcript != nil)\n"
                        }
                        if let view = state.terminals.views[pane.id] {
                            text += "      view: inWindow=\(view.window != nil) superview=\(view.superview.map { String(describing: type(of: $0)) } ?? "nil") frame=\(view.frame) hidden=\(view.isHiddenOrHasHiddenAncestor)\n"
                        }
                    }
                }
                try? text.write(to: URL(fileURLWithPath: dir).appendingPathComponent("focus.txt"), atomically: true, encoding: .utf8)
            }
        }
        center.addObserver(forName: .init("dev.kabuk.action"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let name = note.object as? String else { return }
                NSApp.sendAction(NSSelectorFromString(name), to: target, from: nil)
            }
        }
    }

    /// One character at a time, at a typing pace.
    private static func typeSlowly(_ characters: [Character], into window: NSWindow) {
        guard let first = characters.first else { return }
        if first == "\r" {
            if let terminal = window.firstResponder as? KabukTerminalView {
                terminal.send(source: terminal, data: [13])
            } else {
                press("return", in: window)
            }
        } else if let terminal = window.firstResponder as? KabukTerminalView {
            terminal.send(source: terminal, data: ArraySlice(Array(String(first).utf8)))
        } else if let field = window.firstResponder as? NSTextView {
            field.insertText(String(first), replacementRange: field.selectedRange())
        }
        let rest = Array(characters.dropFirst())
        guard !rest.isEmpty else { return }
        let delay = first == " " ? 0.09 : Double.random(in: 0.035...0.075)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { typeSlowly(rest, into: window) }
        }
    }

    private static func press(_ name: String, in window: NSWindow) {
        let keys: [String: (code: UInt16, characters: String)] = [
            "return": (36, "\r"),
            "escape": (53, "\u{1b}"),
            "up": (126, String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))),
            "down": (125, String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))),
            "ctrl-c": (8, "\u{3}"),
        ]
        guard let key = keys[name] else { return }
        if name == "ctrl-c", let terminal = window.firstResponder as? KabukTerminalView {
            terminal.send(source: terminal, data: [3])
            return
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: key.characters,
                                               charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code) else { continue }
            NSApp.sendEvent(event)
        }
    }
}
