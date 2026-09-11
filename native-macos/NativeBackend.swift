import Foundation

struct NativeHeadphoneState {
    var connected = false
    var name = "Looking for headphones…"
    var model = "Bose Headphones Control"
    var battery: Int?
    var firmware = "—"
    var mode = "—"
    var modes: [String] = []
    var bass = 0.0
    var mid = 0.0
    var treble = 0.0
    var sidetone = "off"
    var supportsSidetone = false
}

@MainActor
final class NativeBackend: ObservableObject {
    @Published private(set) var state = NativeHeadphoneState()
    @Published private(set) var message = "Starting local Bluetooth service…"
    @Published private(set) var isBusy = false

    private var process: Process?
    private var port = Int.random(in: 40000...50000)

    deinit { process?.terminate() }

    func start() {
        guard process == nil else { return }
        guard let executable = Bundle.main.url(forResource: "bose-panel", withExtension: nil, subdirectory: "backend") else {
            message = "The bundled Bluetooth service is missing. Rebuild the app."
            return
        }
        let task = Process()
        task.executableURL = executable
        task.arguments = ["--no-browser"]
        task.environment = ProcessInfo.processInfo.environment.merging([
            "BOSE_UI_HOST": "127.0.0.1",
            "BOSE_UI_PORT": String(port)
        ]) { _, new in new }
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isBusy else { return }
                self.message = "Bluetooth service stopped. Select Reconnect to try again."
            }
        }
        do {
            try task.run()
            process = task
            Task { await waitForBackend() }
        } catch {
            message = "Could not start the Bluetooth service: \(error.localizedDescription)"
        }
    }

    func refresh() {
        Task { await loadState() }
    }

    func reconnect() {
        action("reconnect", args: [:])
    }

    func setMode(_ mode: String) {
        action("set_mode", args: ["name": mode, "announce": false])
    }

    func setEqualizer(bass: Double, mid: Double, treble: Double) {
        action("set_eq", args: ["bass": Int(bass), "mid": Int(mid), "treble": Int(treble)])
    }

    func setSidetone(_ level: String) {
        action("set_sidetone", args: ["level": level])
    }

    private func waitForBackend() async {
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(250))
            if await loadState(silent: true) { return }
        }
        message = "Could not connect. Turn on and connect your headphones, then select Reconnect."
    }

    @discardableResult
    private func loadState(silent: Bool = false) async -> Bool {
        do {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/state")!)
            request.timeoutInterval = 2
            let (data, _) = try await URLSession.shared.data(for: request)
            let payload = try object(from: data)
            guard (payload["ok"] as? Bool) == true, let snapshot = payload["state"] as? [String: Any] else {
                if !silent { message = payload["error"] as? String ?? "Could not read headphones." }
                return false
            }
            apply(snapshot)
            return true
        } catch {
            if !silent { message = "Could not reach the local Bluetooth service." }
            return false
        }
    }

    private func action(_ name: String, args: [String: Any]) {
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/action")!)
                request.httpMethod = "POST"
                request.timeoutInterval = 12
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["action": name, "args": args])
                let (data, _) = try await URLSession.shared.data(for: request)
                let payload = try object(from: data)
                guard (payload["ok"] as? Bool) == true else {
                    message = payload["error"] as? String ?? "The headphones rejected that change."
                    return
                }
                if let snapshot = payload["state"] as? [String: Any] { apply(snapshot) }
                message = "Saved to your headphones."
            } catch {
                message = "Could not save that change."
            }
        }
    }

    private func apply(_ snapshot: [String: Any]) {
        let status = snapshot["status"] as? [String: Any] ?? [:]
        let device = snapshot["device"] as? [String: Any] ?? [:]
        state.connected = true
        state.name = string(status["name"]).isEmpty ? string(device["name"]) : string(status["name"])
        if state.name.isEmpty { state.name = "Bose headphones" }
        state.model = string(device["name"]).isEmpty ? "Bose Headphones Control" : string(device["name"])
        state.battery = integer(status["battery"])
        state.firmware = string(status["firmware"]).isEmpty ? "—" : string(status["firmware"])
        state.mode = string(status["mode"]).isEmpty ? "—" : string(status["mode"])
        state.sidetone = string(status["sidetone"]).isEmpty ? "off" : string(status["sidetone"])
        state.supportsSidetone = (snapshot["features"] as? [String] ?? []).contains("sidetone")
        let profiles = snapshot["profiles"] as? [[String: Any]] ?? []
        state.modes = profiles.compactMap { profile in
            let name = string(profile["name"])
            return name.isEmpty ? nil : name
        }
        if state.modes.isEmpty, state.mode != "—" { state.modes = [state.mode] }
        let eq = status["eq"] as? [[String: Any]] ?? []
        for band in eq {
            switch string(band["name"]).lowercased() {
            case "bass": state.bass = Double(integer(band["current"]) ?? 0)
            case "mid": state.mid = Double(integer(band["current"]) ?? 0)
            case "treble": state.treble = Double(integer(band["current"]) ?? 0)
            default: break
            }
        }
        message = "Connected"
    }

    private func object(from data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "BoseHeadphonesControl", code: 1)
        }
        return value
    }

    private func string(_ value: Any?) -> String { value as? String ?? "" }
    private func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }
}
