import Foundation

/// Runs a command-line tool and collects its output. Call off the main thread.
enum Shell {
    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
        var ok: Bool { status == 0 }
    }

    static func run(_ executable: String, _ args: [String], in cwd: String? = nil, environment: [String: String] = [:]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env.merge(environment) { $1 }
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return Result(status: -1, stdout: "", stderr: error.localizedDescription) }
        // Read both pipes concurrently so a chatty stderr can't block the process.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self))
    }

    static func git(_ args: [String], in cwd: String, environment: [String: String] = [:]) -> Result {
        run("/usr/bin/git", ["-C", cwd] + args, environment: environment)
    }
}
