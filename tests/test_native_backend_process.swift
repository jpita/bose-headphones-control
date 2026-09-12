import Foundation

@main
struct BackendProcessTests {
    static func main() throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sleep")
        task.arguments = ["30"]
        try task.run()

        let controller = BackendProcessController()
        controller.adopt(task)

        precondition(controller.hasProcess)
        precondition(controller.stop())
        task.waitUntilExit()
        precondition(!task.isRunning)
        precondition(!controller.hasProcess)
        precondition(!controller.stop())

        print("Native backend process stops once and clears its reference")
    }
}
