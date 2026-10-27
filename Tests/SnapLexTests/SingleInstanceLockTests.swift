import Darwin
import XCTest
@testable import SnapLex

final class SingleInstanceLockTests: XCTestCase {
    func testDuplicateOpenIsRejectedAndReleasingOwnerAllowsRestart() throws {
        let url = temporaryLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var owner: SingleInstanceLock?
        switch try SingleInstanceLock.acquire(at: url) {
        case .acquired(let lock): owner = lock
        case .alreadyRunning: return XCTFail("First launch must own the lock")
        }
        withExtendedLifetime(owner) {
            do {
                switch try SingleInstanceLock.acquire(at: url) {
                case .alreadyRunning(let pid): XCTAssertEqual(pid, getpid())
                case .acquired: XCTFail("A second launch must not acquire the same lock")
                }
            } catch { XCTFail("\(error)") }
        }
        owner = nil
        guard case .acquired(let restarted) = try SingleInstanceLock.acquire(at: url) else {
            return XCTFail("The next launch must be allowed after exit")
        }
        withExtendedLifetime(restarted) {}
    }

    func testStalePIDFileDoesNotPreventLaunch() throws {
        let url = temporaryLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("999999\n".utf8).write(to: url)
        guard case .acquired(let lock) = try SingleInstanceLock.acquire(at: url) else {
            return XCTFail("A stale file without an OS lock must be reusable")
        }
        withExtendedLifetime(lock) {
            XCTAssertEqual(try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "\(getpid())")
        }
    }

    func testSeparateProcessOwnsLockAndKernelReleasesItAfterTermination() throws {
        let url = temporaryLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let child = Process()
        let output = Pipe()
        let input = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", """
        import fcntl, os, sys
        f = open(sys.argv[1], 'w+')
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        f.write(str(os.getpid()) + '\\n')
        f.flush()
        print('ready', flush=True)
        sys.stdin.buffer.read(1)
        """, url.path]
        child.standardOutput = output
        child.standardInput = input
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readData(ofLength: 6), as: UTF8.self), "ready\n")
        switch try SingleInstanceLock.acquire(at: url) {
        case .alreadyRunning(let pid): XCTAssertEqual(pid, child.processIdentifier)
        case .acquired: XCTFail("Separate processes must share the same exclusion lock")
        }
        child.terminate()
        child.waitUntilExit()
        guard case .acquired(let lock) = try SingleInstanceLock.acquire(at: url) else {
            return XCTFail("Kernel must release the lock when its owner dies")
        }
        withExtendedLifetime(lock) {}
    }

    private func temporaryLockURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapLexSingleInstanceTests-\(UUID().uuidString)")
            .appendingPathComponent("instance.lock")
    }
}
