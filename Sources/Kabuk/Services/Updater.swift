import Foundation
import KabukCore

/// Finds newer Kabuk releases on GitHub, downloads one and swaps it in for the running app.
enum Updater {
    static let repository = "egemenagustos/Kabuk"

    enum Failure: LocalizedError {
        case server(Int)
        case noDownload
        case badArchive(String)
        case cantReplace(String)

        var errorDescription: String? {
            switch self {
            case .server(let code): "GitHub answered with status \(code)."
            case .noDownload: "This release has no Kabuk zip to download."
            case .badArchive(let reason): "The download isn't a usable Kabuk: \(reason)"
            case .cantReplace(let reason): reason
            }
        }
    }

    static var currentVersion: AppVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }

    /// Only a built Kabuk.app looks for updates, not `swift run`.
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Where releases are listed. KABUK_UPDATE_FEED points a test run at a local file instead.
    static var feed: URL {
        if let custom = ProcessInfo.processInfo.environment["KABUK_UPDATE_FEED"], let url = URL(string: custom) { return url }
        return URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!
    }

    static var updatesDir: URL { ShellIntegration.supportDir.appendingPathComponent("Updates", isDirectory: true) }
    /// Written by the install script when it couldn't put the new app in place.
    static var failureFile: URL { updatesDir.appendingPathComponent("install-failed.txt") }

    /// The newest release after this one, or nil when this is the newest.
    static func check() async throws -> AvailableUpdate? {
        guard let current = currentVersion else { return nil }
        var request = URLRequest(url: feed, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Kabuk/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure.server(http.statusCode) }
        return GitHubReleases.update(from: data, current: current)
    }

    /// Why Kabuk can't replace itself where it is, or nil when it can.
    static var installProblem: String? {
        let app = Bundle.main.bundleURL
        let folder = app.deletingLastPathComponent()
        if app.path.contains("/AppTranslocation/") {
            return "macOS is running Kabuk from a temporary copy. Move Kabuk.app into Applications, open it from there, and try again."
        }
        let files = FileManager.default
        guard files.isWritableFile(atPath: folder.path), files.isWritableFile(atPath: app.path) else {
            return "Kabuk can't write to \(folder.path), so it can't replace itself there."
        }
        return nil
    }

    /// Downloads the release and unpacks it next to the others, then checks that it is Kabuk at that
    /// version with an intact signature. Returns the new Kabuk.app.
    static func download(_ update: AvailableUpdate) async throws -> URL {
        guard let url = update.download else { throw Failure.noDownload }
        let (file, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure.server(http.statusCode) }
        let dir = updatesDir.appendingPathComponent(update.version.description, isDirectory: true)
        let files = FileManager.default
        try? files.removeItem(at: dir)
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("Kabuk-\(update.version).zip")
        try files.moveItem(at: file, to: zip)
        return try await Task.detached { try unpack(zip, into: dir, version: update.version) }.value
    }

    private static func unpack(_ zip: URL, into dir: URL, version: AppVersion) throws -> URL {
        let unzip = Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
        guard unzip.ok else { throw Failure.badArchive(unzip.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let app = dir.appendingPathComponent("Kabuk.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw Failure.badArchive("there's no Kabuk.app inside.")
        }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw Failure.badArchive("it's a different app.")
        }
        guard (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) == version else {
            throw Failure.badArchive("it isn't version \(version).")
        }
        let signature = Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard signature.ok else { throw Failure.badArchive("its signature doesn't check out.") }
        // Downloaded by Kabuk itself, but a quarantine flag would make macOS ask again at launch.
        _ = Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// Starts a script that waits for Kabuk to quit, puts `staged` where the running app is, and
    /// opens it again when `relaunch` is set. If the swap fails, the old app stays and the reason is
    /// left in `failureFile` for the next launch.
    static func installWhenQuit(_ staged: URL, relaunch: Bool) throws {
        let script = """
        pid="$1"; staged="$2"; target="$3"; relaunch="$4"; failed="$5"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        backup="$target.previous"
        rm -rf "$backup"
        if ! error=$(mv "$target" "$backup" 2>&1); then
          echo "$error" > "$failed"
        elif ! error=$(mv "$staged" "$target" 2>&1); then
          mv "$backup" "$target"
          echo "$error" > "$failed"
        else
          rm -rf "$backup" "$(dirname "$staged")"
        fi
        [ "$relaunch" = 1 ] && open "$target"
        exit 0
        """
        try? FileManager.default.removeItem(at: failureFile)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "kabuk-update", String(ProcessInfo.processInfo.processIdentifier),
                             staged.path, Bundle.main.bundleURL.path, relaunch ? "1" : "0", failureFile.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// The reason the last install didn't happen, once; nil when it went fine.
    static func takeInstallFailure() -> String? {
        guard let text = try? String(contentsOf: failureFile, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: failureFile)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The release notes inside this app, for What's New.
    static func bundledReleases() -> [ReleaseNote] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Changelog.releases(text)
    }
}
