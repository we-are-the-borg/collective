import Foundation
import Synchronization

/// What a finished (or stopped) command left behind.
public struct CommandResult: Sendable, Equatable {
    /// -1 if the command could not be started.
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    /// The command ran past its timeout and was terminated.
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    /// Exited with 0 within its timeout.
    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

/// Runs a command line tool to its end. A seam so integration probes can be
/// tested without the tools they ask.
public protocol CommandRunner: Sendable {
    func run(executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async -> CommandResult
}

/// Runs commands with `Process` on a GCD thread, so neither the main actor nor
/// the cooperative pool waits for a slow CLI. `run` returns at most about
/// `timeout` + 3 s after the start: the terminate wait and both drain waits.
public struct ProcessCommandRunner: CommandRunner {
    /// How long each wait for the output lasts. A child that inherited the
    /// pipes can keep them open past its parent, so after the process ended
    /// `run` waits up to twice this: once for the pipes to close, once for the
    /// cancelled reads to finish. A timeout adds one more for the terminate.
    private static let drainGrace: DispatchTimeInterval = .seconds(1)

    /// How many reads a cancelled source still makes to take what is left in
    /// its pipe. A bound, so a child that goes on writing can't hold it.
    static let finalReads = 16

    public init() {}

    public func run(executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.runBlocking(executable, arguments, environment, timeout))
            }
        }
    }

    private static func runBlocking(_ executable: URL, _ arguments: [String], _ environment: [String: String],
                                    _ timeout: Duration) -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            return CommandResult(exitCode: -1, stderr: "\(error)")
        }

        // Both pipes are read at the same time: a full stderr pipe would
        // otherwise block the process while it is waited on for stdout. The
        // output is kept as it arrives, so a child that inherited the pipes
        // and outlives its parent can't take it with it.
        let stdout = Output(), stderr = Output()
        let readers = DispatchQueue(label: "ProcessCommandRunner.readers")
        let drained = DispatchGroup()
        let sources = [(outPipe, stdout), (errPipe, stderr)].map { pipe, output in
            startReading(pipe.fileHandleForReading, into: output, on: readers, group: drained)
        }

        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        var timedOut = false
        if exited.wait(timeout: .now() + seconds) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + drainGrace) == .timedOut { kill(process.processIdentifier, SIGKILL) }
        }
        if drained.wait(timeout: .now() + drainGrace) == .timedOut {
            sources.forEach { $0.cancel() }
            // The handlers never block, so the cancel handlers follow shortly.
            _ = drained.wait(timeout: .now() + drainGrace)
        }
        return CommandResult(
            exitCode: process.isRunning ? -1 : process.terminationStatus,
            stdout: stdout.text,
            stderr: stderr.text,
            timedOut: timedOut
        )
    }

    /// Reads `handle` without ever blocking a thread, until EOF or until the
    /// returned source is cancelled. Dispatch runs the cancel handler after the
    /// last event handler, so the handle is closed only when no read is under
    /// way, and `group` is left once per stream.
    static func startReading(_ handle: FileHandle, into output: Output, on queue: DispatchQueue,
                              group: DispatchGroup) -> any DispatchSourceRead {
        let fd = handle.fileDescriptor
        // Without O_NONBLOCK the event handler still only reads when the pipe
        // is readable, but the final reads could block, so they are skipped.
        let flags = fcntl(fd, F_GETFL)
        let nonBlocking = flags != -1 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1
        // One buffer for both handlers: they run on `queue` and never at the
        // same time, so it is only ever touched by one read.
        var buffer = [UInt8](repeating: 0, count: 65536)
        func readOnce() -> Int {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 { output.append(buffer[..<count]) }
            return count
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            let count = readOnce()
            if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                source.cancel()
            }
        }
        source.setCancelHandler {
            // Cancelling drops what the event handler hasn't read yet, which
            // on a loaded machine can be the last output before the exit.
            if nonBlocking {
                for _ in 0..<finalReads {
                    let count = readOnce()
                    if count == 0 || (count < 0 && errno != EINTR) { break }
                }
            }
            try? handle.close()
            group.leave()
        }
        group.enter()
        source.resume()
        return source
    }

    /// One pipe's output, appended to by its read source.
    final class Output: Sendable {
        private let data = Mutex(Data())
        func append(_ chunk: ArraySlice<UInt8>) { data.withLock { $0.append(contentsOf: chunk) } }
        var text: String { String(decoding: data.withLock { $0 }, as: UTF8.self) }
    }
}
