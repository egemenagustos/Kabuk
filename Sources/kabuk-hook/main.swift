// kabuk-hook: forwards Claude Code hook and Codex notify events to the running Kabuk app.
//
//   kabuk-hook claude <HookEventName>   (hook JSON on stdin)
//   kabuk-hook codex '<notify json>'
//
// For PermissionRequest it waits for the user's answer in Kabuk and prints Claude's
// decision JSON; with no answer it prints nothing and Claude asks in the terminal as usual.
//
// Outside a Kabuk pane (no KABUK_PANE_ID) it does nothing, and it always exits 0 so a
// missing app never breaks the agent.
import Foundation
import KabukCore

let env = ProcessInfo.processInfo.environment
let args = CommandLine.arguments

guard let pane = env["KABUK_PANE_ID"], let socketPath = env["KABUK_SOCKET"], args.count >= 3 else {
    exit(0)
}

func json(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

func firstLine(_ text: String?, limit: Int = 200) -> String? {
    guard let text else { return nil }
    let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : String(trimmed.prefix(limit))
}

/// The Codex rollout for a thread lives at $CODEX_HOME/sessions/YYYY/MM/DD/rollout-…-<thread id>.jsonl,
/// CODEX_HOME being ~/.codex unless set.
/// Without an id, the most recently written rollout is the one that just finished a turn.
func codexRollout(threadID: String?) -> URL? {
    let home = env["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
    let root = home.appendingPathComponent("sessions")
    guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else {
        return nil
    }
    var newest: (url: URL, date: Date)?
    for case let url as URL in files where url.pathExtension == "jsonl" {
        if let threadID, url.lastPathComponent.hasSuffix("\(threadID).jsonl") { return url }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if newest == nil || date > newest!.date { newest = (url, date) }
    }
    return threadID == nil ? newest?.url : nil
}

/// How long a permission request may wait for an answer before Claude asks in the terminal.
let permissionWait: TimeInterval = 300

var event: HookEvent
var suggestions: Any?
switch args[1] {
case "claude":
    let payload = isatty(STDIN_FILENO) == 0 ? json(FileHandle.standardInput.readDataToEndOfFile()) : [:]
    if args[2] == "PermissionRequest" {
        let tool = payload["tool_name"] as? String ?? "Tool"
        suggestions = payload["permission_suggestions"]
        event = HookEvent(pane: pane, source: "claude", event: args[2],
                          request: UUID().uuidString, tool: tool,
                          detail: PermissionSummary.detail(tool: tool, input: payload["tool_input"] as? [String: Any] ?? [:]),
                          canAlwaysAllow: !((suggestions as? [Any])?.isEmpty ?? true))
        break
    }
    var tokens: TokenUsage?
    if args[2] == "Stop", let path = payload["transcript_path"] as? String,
       let transcript = FileManager.default.contents(atPath: path) {
        tokens = TokenUsage.fromClaudeTranscript(transcript)
    }
    event = HookEvent(pane: pane, source: "claude", event: args[2],
                      message: firstLine(payload["message"] as? String),
                      prompt: firstLine(payload["prompt"] as? String),
                      kind: payload["notification_type"] as? String,
                      tokens: tokens,
                      session: payload["session_id"] as? String)
case "codex":
    let payload = json(Data(args[2].utf8))
    let inputs = payload["input-messages"] as? [String]
    let type = payload["type"] as? String ?? "unknown"
    var tokens: TokenUsage?
    if type == "agent-turn-complete", let rollout = codexRollout(threadID: payload["thread-id"] as? String),
       let data = try? Data(contentsOf: rollout) {
        tokens = TokenUsage.fromCodexRollout(data)
    }
    event = HookEvent(pane: pane, source: "codex", event: type,
                      message: firstLine(payload["last-assistant-message"] as? String),
                      prompt: firstLine(inputs?.last),
                      tokens: tokens,
                      session: payload["thread-id"] as? String)
default:
    exit(0)
}

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { exit(0) }
withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
    buffer.copyBytes(from: pathBytes)
}
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else { exit(0) }
let line = event.encodedLine()
_ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

if event.request != nil {
    // Done writing; the app answers on the same connection.
    shutdown(fd, SHUT_WR)
    var timeout = timeval(tv_sec: Int(permissionWait), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 512)
    while !reply.contains(UInt8(ascii: "\n")) {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        reply.append(contentsOf: buffer[0..<n])
    }
    let answer = (json(reply)["decision"] as? String).flatMap(PermissionDecision.init(rawValue:)) ?? .ask
    if let output = PermissionSummary.hookOutput(answer, suggestions: suggestions) {
        print(output)
    }
}
close(fd)
exit(0)
