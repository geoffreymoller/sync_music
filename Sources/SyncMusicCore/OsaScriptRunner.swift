import Darwin
import Dispatch
import Foundation

public struct OsaScriptError: Error, LocalizedError, Sendable {
    public let operation: String
    public let terminationStatus: Int32
    public let stdoutText: String
    public let stderrText: String
    public let durationMilliseconds: Int

    public init(
        operation: String,
        terminationStatus: Int32,
        stdoutText: String,
        stderrText: String,
        durationMilliseconds: Int
    ) {
        self.operation = operation
        self.terminationStatus = terminationStatus
        self.stdoutText = stdoutText
        self.stderrText = stderrText
        self.durationMilliseconds = durationMilliseconds
    }

    public var message: String {
        let combined = stderrText.isEmpty ? stdoutText : stderrText
        return combined.isEmpty ? "Unknown osascript failure during \(operation)." : combined
    }

    public var category: FailureCategory {
        FailureCategory.classify(message: message, operation: operation)
    }

    public var errorDescription: String? { message }
}

public struct OsaScriptTimeoutError: Error, LocalizedError, Sendable {
    public let operation: String
    public let timeoutInterval: TimeInterval
    public let stdoutText: String
    public let stderrText: String
    public let durationMilliseconds: Int

    public init(
        operation: String,
        timeoutInterval: TimeInterval,
        stdoutText: String,
        stderrText: String,
        durationMilliseconds: Int
    ) {
        self.operation = operation
        self.timeoutInterval = timeoutInterval
        self.stdoutText = stdoutText
        self.stderrText = stderrText
        self.durationMilliseconds = durationMilliseconds
    }

    public var message: String {
        "osascript timed out after \(Int(timeoutInterval.rounded())) seconds during \(operation)."
    }

    public var errorDescription: String? { message }
}

public struct OsaScriptExecution: Sendable {
    public let stdoutText: String
    public let stderrText: String
    public let terminationStatus: Int32
    public let durationMilliseconds: Int

    public init(
        stdoutText: String,
        stderrText: String,
        terminationStatus: Int32,
        durationMilliseconds: Int
    ) {
        self.stdoutText = stdoutText
        self.stderrText = stderrText
        self.terminationStatus = terminationStatus
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct OsaScriptRunner: Sendable {
    public let timeoutInterval: TimeInterval

    public init(timeoutInterval: TimeInterval = 300) {
        self.timeoutInterval = timeoutInterval
    }

    public func run(
        scriptName: String,
        script: String,
        arguments: [String] = []
    ) throws -> OsaScriptExecution {
        let start = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"] + arguments

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()

        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin

        try process.run()

        let stdoutCapture = PipeCapture(handle: stdout.fileHandleForReading)
        let stderrCapture = PipeCapture(handle: stderr.fileHandleForReading)
        stdoutCapture.start()
        stderrCapture.start()

        if let data = script.data(using: .utf8) {
            stdin.fileHandleForWriting.write(data)
        }
        stdin.fileHandleForWriting.closeFile()

        let didTimeOut = waitForExit(of: process, timeout: timeoutInterval) == false
        if didTimeOut {
            terminate(process)
        }

        process.waitUntilExit()

        let stdoutData = stdoutCapture.waitForData()
        let stderrData = stderrCapture.waitForData()
        let stdoutText = String(decoding: stdoutData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let stderrText = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let durationMilliseconds = Int(Date().timeIntervalSince(start) * 1_000)

        if didTimeOut {
            throw OsaScriptTimeoutError(
                operation: scriptName,
                timeoutInterval: timeoutInterval,
                stdoutText: stdoutText,
                stderrText: stderrText,
                durationMilliseconds: durationMilliseconds
            )
        }

        guard process.terminationStatus == 0 else {
            throw OsaScriptError(
                operation: scriptName,
                terminationStatus: process.terminationStatus,
                stdoutText: stdoutText,
                stderrText: stderrText,
                durationMilliseconds: durationMilliseconds
            )
        }

        return OsaScriptExecution(
            stdoutText: stdoutText,
            stderrText: stderrText,
            terminationStatus: process.terminationStatus,
            durationMilliseconds: durationMilliseconds
        )
    }

    private func waitForExit(of process: Process, timeout: TimeInterval) -> Bool {
        let effectiveTimeout = max(0.1, timeout)
        let deadline = Date().addingTimeInterval(effectiveTimeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        return process.isRunning == false
    }

    private func terminate(_ process: Process) {
        if process.isRunning {
            process.interrupt()
        }
        if waitForExit(of: process, timeout: 0.5) {
            return
        }

        if process.isRunning {
            process.terminate()
        }
        if waitForExit(of: process, timeout: 0.5) {
            return
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = waitForExit(of: process, timeout: 0.5)
        }
    }
}

private final class PipeCapture: @unchecked Sendable {
    private let handle: FileHandle
    private let completion = DispatchSemaphore(value: 0)
    private var data = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.completion.signal() }
            self.data = self.handle.readDataToEndOfFile()
        }
    }

    func waitForData() -> Data {
        completion.wait()
        return data
    }
}
