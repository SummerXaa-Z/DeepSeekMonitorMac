import Foundation

/// Process 的 stdout / stderr 共用有限容量的 pipe 缓冲区，必须并发排空。
/// 如果先同步读 stdout，而子进程先写满 stderr，双方会互相等待并永久卡住。
enum ProcessPipeReader {
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()

        func setStdout(_ data: Data) {
            lock.lock()
            stdout = data
            lock.unlock()
        }

        func setStderr(_ data: Data) {
            lock.lock()
            stderr = data
            lock.unlock()
        }

        func snapshot() -> (stdout: Data, stderr: Data) {
            lock.lock()
            defer { lock.unlock() }
            return (stdout, stderr)
        }
    }

    static func read(
        stdout outPipe: Pipe,
        stderr errPipe: Pipe,
        process: Process
    ) -> (stdout: Data, stderr: Data) {
        let storage = Storage()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            storage.setStdout(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            storage.setStderr(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        process.waitUntilExit()
        group.wait()
        return storage.snapshot()
    }
}
