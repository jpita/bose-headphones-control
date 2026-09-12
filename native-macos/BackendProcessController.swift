import Foundation

final class BackendProcessController {
    private var process: Process?

    var hasProcess: Bool { process != nil }
    var isRunning: Bool { process?.isRunning ?? false }
    var exitStatus: Int32? {
        guard let process, !process.isRunning else { return nil }
        return process.terminationStatus
    }

    func adopt(_ process: Process) {
        precondition(self.process == nil, "A backend process is already active")
        self.process = process
    }

    func clearExitedProcess() {
        guard let process, !process.isRunning else { return }
        self.process = nil
    }

    @discardableResult
    func stop() -> Bool {
        guard let process else { return false }
        self.process = nil
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
        return true
    }
}
