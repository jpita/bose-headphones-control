import Foundation

final class BackendProcessController {
    private var process: Process?

    var hasProcess: Bool { process != nil }

    func adopt(_ process: Process) {
        precondition(self.process == nil, "A backend process is already active")
        self.process = process
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
