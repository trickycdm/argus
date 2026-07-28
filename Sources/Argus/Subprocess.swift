import Foundation

/// The one process-spawning helper in the app. Correctness properties:
/// the termination handler is installed before run() so a fast exit can't be
/// missed, and both pipes are drained to EOF concurrently and independently
/// of termination — a child writing more than the ~64KB pipe buffer to either
/// stream can never deadlock the await.
enum Subprocess {
    struct Output {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    static func run(_ executable: String, _ arguments: [String],
                    environment: [String: String]? = nil) async -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, new in new }
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let (exit, exitContinuation) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { proc in
            exitContinuation.yield(proc.terminationStatus)
            exitContinuation.finish()
        }
        do {
            try process.run()
        } catch {
            return Output(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        async let stdout = drain(outPipe)
        async let stderr = drain(errPipe)
        var status: Int32 = -1
        for await code in exit { status = code }
        return await Output(status: status, stdout: stdout, stderr: stderr)
    }

    /// Blocking read on a GCD thread so the cooperative pool is never tied up.
    private static func drain(_ pipe: Pipe) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}

/// Escaping and validation for values that cross into AppleScript or shell
/// source. Session/iTerm ids originate from untrusted hook input — validate
/// their shape outright rather than trying to escape arbitrary content.
enum Escape {
    /// Claude session ids and iTerm session UUIDs are hex-and-dash strings;
    /// anything else is refused before it reaches AppleScript.
    static func isUUIDLike(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// Escapes a value for interpolation inside an AppleScript string literal.
    static func appleScriptString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Wraps a value in shell single quotes, closing/reopening around any
    /// embedded quote: it's → 'it'\''s'.
    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
