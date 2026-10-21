import Foundation

/// A release number such as 0.2.0, compared part by part (0.10 comes after 0.9).
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    /// Accepts "0.2.0" and "v0.2.0"; nil for anything else, such as "Unreleased".
    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.parts = parts.map { $0! }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    public func hash(into hasher: inout Hasher) {
        var parts = parts
        while parts.last == 0 { parts.removeLast() }
        hasher.combine(parts)
    }
}

/// One version's section of the release notes: "### Added" headings and "- " entries.
public struct ReleaseNote: Equatable, Sendable, Identifiable {
    public var version: AppVersion
    /// yyyy-mm-dd, when known.
    public var date: String?
    public var body: String

    public var id: String { version.description }

    public init(version: AppVersion, date: String?, body: String) {
        self.version = version
        self.date = date
        self.body = body
    }

    public enum Line: Equatable, Sendable {
        case heading(String)
        case entry(String)
    }

    /// The headings and entries, with an entry's wrapped lines joined back together.
    public var lines: [Line] {
        var lines: [Line] = []
        for raw in body.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { lines.append(.heading(title)) }
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                lines.append(.entry(String(line.dropFirst(2))))
            } else if !line.isEmpty, case .entry(let text)? = lines.last {
                lines[lines.count - 1] = .entry(text + " " + line)
            }
        }
        return lines
    }
}

public enum Changelog {
    /// Every released version in CHANGELOG.md, newest first. Unreleased is left out.
    public static func releases(_ text: String) -> [ReleaseNote] {
        var notes: [ReleaseNote] = []
        var current: (version: AppVersion?, date: String?)?
        var body: [String] = []
        func flush() {
            if let current, let version = current.version {
                notes.append(ReleaseNote(version: version, date: current.date,
                                         body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            body = []
        }
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("## ["), let close = line.firstIndex(of: "]") {
                flush()
                let name = String(line[line.index(line.startIndex, offsetBy: 4)..<close])
                let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                let date = rest.hasPrefix("- ") ? String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces) : nil
                current = (AppVersion(name), date)
            } else if line.hasPrefix("[") && line.contains("]: ") {
                // The compare links at the bottom end the last section.
                flush()
                current = nil
            } else if current != nil {
                body.append(line)
            }
        }
        flush()
        return notes.sorted { $0.version > $1.version }
    }
}

/// A newer release on GitHub, with the notes of every version between this one and it.
public struct AvailableUpdate: Equatable, Sendable {
    public var version: AppVersion
    /// Newest first.
    public var notes: [ReleaseNote]
    /// The release's zipped Kabuk.app; nil when the release has none.
    public var download: URL?
    /// The release on github.com.
    public var page: URL

    public init(version: AppVersion, notes: [ReleaseNote], download: URL?, page: URL) {
        self.version = version
        self.notes = notes
        self.download = download
        self.page = page
    }
}

public enum GitHubReleases {
    /// The newest release after `current` in a `GET /repos/{owner}/{repo}/releases` reply. Drafts,
    /// prereleases and tags that aren't version numbers are skipped.
    public static func update(from data: Data, current: AppVersion) -> AvailableUpdate? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        var newer: [(note: ReleaseNote, release: [String: Any])] = []
        for release in list {
            guard release["draft"] as? Bool != true, release["prerelease"] as? Bool != true,
                  let tag = release["tag_name"] as? String, let version = AppVersion(tag), version > current else { continue }
            let date = (release["published_at"] as? String).map { String($0.prefix(10)) }
            let body = (release["body"] as? String ?? "").replacingOccurrences(of: "\r\n", with: "\n")
            newer.append((ReleaseNote(version: version, date: date, body: body), release))
        }
        newer.sort { $0.note.version > $1.note.version }
        guard let latest = newer.first, let page = (latest.release["html_url"] as? String).flatMap(URL.init(string:)) else {
            return nil
        }
        let assets = latest.release["assets"] as? [[String: Any]] ?? []
        let zips = assets.filter { ($0["name"] as? String)?.hasSuffix(".zip") == true }
        let asset = zips.first { $0["name"] as? String == "Kabuk-\(latest.note.version).zip" } ?? zips.first
        let download = (asset?["browser_download_url"] as? String).flatMap(URL.init(string:))
        return AvailableUpdate(version: latest.note.version, notes: newer.map(\.note), download: download, page: page)
    }
}

public enum WhatsNew {
    /// The last version that didn't record which release notes it had shown.
    public static let untracked = AppVersion("0.1.0")!

    /// The release notes to show on this launch, newest first: every version after the one seen last,
    /// up to this one. A first install shows nothing; state saved by a version that didn't keep track
    /// counts as `untracked`.
    public static func notes(_ releases: [ReleaseNote], lastSeen: String?, hasState: Bool, current: AppVersion) -> [ReleaseNote] {
        guard let seen = lastSeen.flatMap(AppVersion.init) ?? (hasState ? untracked : nil), seen < current else { return [] }
        return releases.filter { $0.version > seen && $0.version <= current }
    }
}

public enum UpdateSchedule {
    /// Automatic checks happen at most this often.
    public static let interval: TimeInterval = 24 * 60 * 60

    public static func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval || now < lastCheck
    }
}
