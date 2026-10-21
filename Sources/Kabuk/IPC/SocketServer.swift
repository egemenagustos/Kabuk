import Foundation
import KabukCore

/// Listens on a Unix domain socket for newline-delimited `HookEvent` JSON.
/// Each client connects, writes a line or two, and closes its write side. An event with a
/// `request` id keeps the connection open until the app answers through its `Reply`.
final class SocketServer {
    /// Answers a waiting client once; later calls do nothing.
    typealias Reply = (HookReply) -> Void

    let path: String
    private let queue = DispatchQueue(label: "kabuk.socket")
    private var listenSource: DispatchSourceRead?
    private var clients: [Int32: (source: DispatchSourceRead, buffer: Data)] = [:]
    /// Clients waiting for a reply; their descriptor outlives the read source.
    private var waiting: Set<Int32> = []
    private let onEvent: (HookEvent, Reply?) -> Void

    init(path: String, onEvent: @escaping (HookEvent, Reply?) -> Void) {
        self.path = path
        self.onEvent = onEvent
    }

    func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 32) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            close(fd)
            throw error
        }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        listenSource = source
    }

    func stop() {
        listenSource?.cancel()
        listenSource = nil
        unlink(path)
    }

    private func acceptClients(_ listenFD: Int32) {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            _ = fcntl(client, F_SETFL, O_NONBLOCK)
            // Writing a reply to a hook that already gave up must not raise SIGPIPE.
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
            source.setEventHandler { [weak self] in self?.read(client) }
            source.setCancelHandler { [weak self] in
                if self?.waiting.contains(client) != true { close(client) }
            }
            clients[client] = (source, Data())
            source.resume()
        }
    }

    private func makeReply(_ client: Int32) -> Reply {
        var answered = false
        return { [weak self, queue] reply in
            queue.async {
                guard !answered else { return }
                answered = true
                self?.waiting.remove(client)
                let line = reply.encodedLine()
                // The hook may have given up already; a failed write just means nobody is listening.
                _ = line.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
                close(client)
            }
        }
    }

    private func read(_ client: Int32) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(client, &chunk, chunk.count)
            if n > 0 {
                clients[client]?.buffer.append(contentsOf: chunk[0..<n])
                continue
            }
            if n < 0 && errno == EAGAIN { return }
            // EOF or error: the client has said everything.
            guard let entry = clients.removeValue(forKey: client) else { return }
            let events = HookEvent.parseAll(entry.buffer)
            let request = events.first { $0.request != nil }
            if request != nil { waiting.insert(client) }
            entry.source.cancel()
            for event in events where event.request == nil { onEvent(event, nil) }
            if let request { onEvent(request, makeReply(client)) }
            return
        }
    }
}
