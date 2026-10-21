import Foundation

enum RunnerError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
}

struct CommandResult {
    var status: Int32
    var output: Data
    var text: String { String(decoding: output, as: UTF8.self) }
}

/// Runs a tool directly (no shell), so arguments are never re-parsed.
enum CommandRunner {
    static func run(_ executable: String, _ arguments: [String],
                    timeout: TimeInterval, logTo logURL: URL? = nil) async throws -> CommandResult {
        // Output goes to a temp file rather than a pipe so a chatty xcodebuild can't fill the pipe and stall.
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepsigned-\(UUID().uuidString).out")
        FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: outURL) }
        let handle = try FileHandle(forWritingTo: outURL)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice

        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                cont.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
        let data = (try? Data(contentsOf: outURL)) ?? Data()
        if let logURL { Log.appendRaw(data, to: logURL) }
        return CommandResult(status: status, output: data)
    }
}

enum Log {
    static func appendRaw(_ data: Data, to url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    }
}
