import Foundation
import Testing
@testable import CollectiveKit

/// Runs real processes, so it covers what the fakes in the probe tests can't.
@Suite struct ProcessCommandRunnerTests {
    @Test func collectsTheOutputAndExitCode() async {
        let result = await ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hello", "world"],
                                                      environment: [:], timeout: .seconds(5))
        #expect(result == CommandResult(exitCode: 0, stdout: "hello world\n"))
    }

    /// Checks the pid, not a clock: the full suite can keep `run` from being
    /// scheduled for tens of seconds. A runner that waited the command
    /// out would hang for the whole `sleep` instead of passing.
    @Test func terminatesACommandPastItsTimeout() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pidFile = dir.appendingPathComponent("command.pid")
        let commandPID = { (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
        // Only kill what the test has not shown gone: a reused pid could be an unrelated process.
        var gone = false
        defer {
            if !gone, let pid = commandPID() { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: dir)
        }
        // The timer starts right after launch, so the timeout has to leave `sh` time to write
        // its pid under load, or there is no pid file to check.
        // `exec`, so the pid in the file is the process the runner has to terminate.
        let result = await ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sh"),
                                                      arguments: ["-c", "echo $$ > \"$1\"; exec /bin/sleep 600", "sh", pidFile.path],
                                                      environment: [:], timeout: .seconds(2))
        #expect(result.timedOut)
        #expect(!result.succeeded)
        let pid = try #require(commandPID())
        let alive = kill(pid, 0)
        let error = errno // read before `#expect` can clobber it
        gone = alive == -1 && error == ESRCH
        #expect(gone)
    }

    @Test func keepsTheOutputWrittenBeforeTheTimeout() async {
        // Guards against a regression: the old blocking reads passed this too.
        // `exec`, so the terminated process is the sleep itself and no child is left behind.
        let result = await ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sh"),
                                                      arguments: ["-c", "echo before; echo oops >&2; exec /bin/sleep 30"],
                                                      environment: [:], timeout: .milliseconds(500))
        #expect(result.timedOut)
        #expect(result.stdout == "before\n")
        #expect(result.stderr == "oops\n")
    }

    @Test func keepsTheOutputWhenABackgroundChildHoldsThePipes() async throws {
        let (result, childAlive) = try await runWithBackgroundChild("echo before")
        #expect(childAlive)
        #expect(result == CommandResult(exitCode: 0, stdout: "before\n"))
    }

    @Test func keepsTheErrorOutputWhenABackgroundChildHoldsThePipes() async throws {
        let (result, childAlive) = try await runWithBackgroundChild("echo before >&2")
        #expect(childAlive)
        #expect(result == CommandResult(exitCode: 0, stderr: "before\n"))
    }

    @Test func readsLargeOutputOnBothStreamsCompletely() async {
        // More than a pipe buffer on each stream, stderr first: reading only
        // stdout would leave the command blocked on a full stderr pipe.
        let script = """
            /usr/bin/head -c 200000 /dev/zero | /usr/bin/tr '\\0' e >&2
            /usr/bin/head -c 200000 /dev/zero | /usr/bin/tr '\\0' o
            """
        let result = await ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                                                      environment: [:], timeout: .seconds(10))
        #expect(result.exitCode == 0)
        #expect(!result.timedOut)
        #expect(result.stdout == String(repeating: "o", count: 200_000))
        #expect(result.stderr == String(repeating: "e", count: 200_000))
    }

    @Test func keepsWhatIsStillInThePipeWhenTheReadIsCancelled() {
        // The queue is held, so no event handler can read before the cancel:
        // only the cancel handler can take the output. The write end stays
        // open, so a blocking read there would hang instead of returning.
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data("last words\n".utf8))
        let queue = DispatchQueue(label: "ProcessCommandRunnerTests.readers")
        queue.suspend()
        let output = ProcessCommandRunner.Output(), group = DispatchGroup()
        let source = ProcessCommandRunner.startReading(pipe.fileHandleForReading, into: output, on: queue, group: group)
        source.cancel()
        queue.resume()
        #expect(group.wait(timeout: .now() + 5) == .success)
        #expect(output.text == "last words\n")
    }

    @Test func boundsTheFinalReadsWhenTheWriterIsAlwaysAhead() throws {
        // Twice what the final reads may take is queued, as from a child that
        // goes on writing: they must stop at their bound instead of reading
        // until the writer does. A pipe holds only 64 KiB and `yes` can't
        // outpace the reads, so a socket pair with a large buffer stands in.
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let (reader, writer) = (fds[0], fds[1])
        defer { close(writer) }
        let bound = ProcessCommandRunner.finalReads * 65536
        var size = Int32(2 * bound)
        for fd in fds {
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        _ = fcntl(writer, F_SETFL, fcntl(writer, F_GETFL) | O_NONBLOCK)
        let chunk = [UInt8](repeating: UInt8(ascii: "y"), count: 65536)
        var queued = 0
        while queued < 2 * bound {
            let count = chunk.withUnsafeBytes { Darwin.write(writer, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            queued += count
        }
        try #require(queued > bound)

        let queue = DispatchQueue(label: "ProcessCommandRunnerTests.readers")
        queue.suspend()
        let output = ProcessCommandRunner.Output(), group = DispatchGroup()
        let source = ProcessCommandRunner.startReading(FileHandle(fileDescriptor: reader), into: output, on: queue, group: group)
        source.cancel()
        queue.resume()
        #expect(group.wait(timeout: .now() + 5) == .success)
        // A socket read may return less than 64 KiB, so only the bounds hold.
        let received = output.text.utf8.count
        #expect(received > 0 && received <= bound && received < queued)
        // The reader's end is closed, so the writer's end reads EOF, not
        // EAGAIN. The socket may go a moment after the descriptor, hence the poll.
        var event = pollfd(fd: writer, events: Int16(POLLIN), revents: 0)
        #expect(poll(&event, 1, 5000) == 1)
        var byte: UInt8 = 0
        #expect(Darwin.read(writer, &byte, 1) == 0)
    }

    @Test func aMissingExecutableFails() async {
        let result = await ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/nonexistent/tool"), arguments: [],
                                                      environment: [:], timeout: .seconds(1))
        #expect(result.exitCode == -1)
        #expect(!result.timedOut)
    }

    /// Runs `script` after starting a background `sleep` that inherits stdout
    /// and stderr, then kills only that child through its pid file. Whether
    /// the child was still alive when the result arrived tells that the runner
    /// didn't wait for the pipes to close; a clock wouldn't, because the full
    /// suite can keep `run` from being scheduled for many seconds.
    private func runWithBackgroundChild(_ script: String) async throws -> (CommandResult, childAlive: Bool) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pidFile = dir.appendingPathComponent("child.pid")
        let childPID = { (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
        defer {
            if let pid = childPID() { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: dir)
        }
        let result = await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/bin/sleep 15 & echo $! > \"$1\"; \(script); exit 0", "sh", pidFile.path],
            environment: [:], timeout: .seconds(10))
        return (result, childPID().map { kill($0, 0) == 0 } ?? false)
    }
}
