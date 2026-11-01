import Foundation
import Darwin

extension RemoteFileSystem {
    public static func run(_ invocation: RemoteInvocation, _ token: RemoteCancellation) throws -> Data {
        try token.check()
        let process = Process(); process.executableURL = URL(fileURLWithPath: invocation.executable); process.arguments = invocation.arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"; environment["SSH_ASKPASS_REQUIRE"] = "never"
        process.environment = environment
        let output = Pipe(), errors = Pipe(), input = Pipe()
        process.standardError = errors
        var fileOutput: FileHandle?
        var fileInput: FileHandle?
        if let destination = invocation.outputFile {
            let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            fileOutput = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); process.standardOutput = fileOutput
        } else { process.standardOutput = output }
        if let source = invocation.inputFile { fileInput = try FileHandle(forReadingFrom: source); process.standardInput = fileInput }
        else if invocation.input != nil { process.standardInput = input }
        else { process.standardInput = FileHandle.nullDevice }
        defer { try? fileInput?.close(); try? fileOutput?.close(); try? token.attach(nil) }
        try token.attach(process)
        try process.run()
        if token.isCancelled { process.terminate() }
        let group = DispatchGroup()
        let collectedOutput = RemoteDataBox(), collectedErrors = RemoteDataBox()
        if fileOutput == nil {
            group.enter(); DispatchQueue.global().async {
                Self.collect(output.fileHandleForReading, into: collectedOutput, limit: 16 * 1024 * 1024, stopOnOverflow: process)
                group.leave()
            }
        }
        group.enter(); DispatchQueue.global().async { Self.collect(errors.fileHandleForReading, into: collectedErrors, limit: 8192); group.leave() }
        if let bytes = invocation.input { try input.fileHandleForWriting.write(contentsOf: bytes); try input.fileHandleForWriting.close() }
        process.waitUntilExit(); group.wait()
        try token.check()
        guard !collectedOutput.overflow else { throw RemoteError.process("Die Serverantwort überschreitet 16 MB. Bitte ein kleineres Unterverzeichnis öffnen.") }
        guard process.terminationStatus == 0 else {
            let message = String(data: collectedErrors.data.prefix(8192), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteError.process(message?.isEmpty == false ? message! : "Der Server hat den Vorgang abgelehnt (\(process.terminationStatus)).")
        }
        return collectedOutput.data
    }

    private static func collect(_ handle: FileHandle, into box: RemoteDataBox, limit: Int, stopOnOverflow process: Process? = nil) {
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            let available = max(0, limit - box.data.count)
            box.data.append(chunk.prefix(available))
            if chunk.count > available {
                box.overflow = true
                if process?.isRunning == true { process?.terminate() }
            }
        }
    }
}

private final class RemoteDataBox: @unchecked Sendable { var data = Data(); var overflow = false }
