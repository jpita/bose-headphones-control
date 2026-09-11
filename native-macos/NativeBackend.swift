import Foundation

struct NativeProfile: Identifiable, Equatable {
    let id: Int
    var name: String
    let editable: Bool
    let configured: Bool
    var cncLevel: Int
    var windBlock: Bool
    var ancToggle: Bool
    var spatial: Int
}

struct NativeButtonMapping: Identifiable {
    let id: String
    let button: String
    let event: String
    let action: String
}

struct NativeHeadphoneState {
    var connected = false
    var name = "Looking for headphones…"
    var model = "Bose Headphones Control"
    var battery: Int?
    var firmware = "—"
    var mode = "—"
    var modeIndex: Int?
    var profiles: [NativeProfile] = []
    var eq: [Double] = [0, 0, 0]
    var cncLevel = 0
    var cncMax = 10
    var sidetone = "off"
    var promptsEnabled = false
    var promptsLanguage = ""
    var autoPause = false
    var autoAnswer = false
    var features: Set<String> = []
    var buttons: [NativeButtonMapping] = []

    var activeProfile: NativeProfile? { profiles.first { $0.id == modeIndex } }
    var playableProfiles: [NativeProfile] { profiles.filter { !$0.editable || !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    func supports(_ feature: String) -> Bool { features.contains(feature) }
}

@MainActor
final class NativeBackend: ObservableObject {
    static let shared = NativeBackend()
    @Published private(set) var state = NativeHeadphoneState()
    @Published private(set) var message = "Starting local Bluetooth service…"
    @Published private(set) var isBusy = false
    @Published private(set) var writeLog: [String] = []
    @Published private(set) var rawLog: [String] = []

    private var process: Process?
    private var port = Int.random(in: 40000...50000)

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
            "BOSE_UI_HOST": "127.0.0.1", "BOSE_UI_PORT": String(port)
        ]) { _, new in new }
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.message = "Bluetooth service stopped. Select Reconnect to try again." }
        }
        do { try task.run(); process = task; Task { await waitForBackend() } }
        catch { message = "Could not start the Bluetooth service: \(error.localizedDescription)" }
    }

    func stop() {
        guard let task = process else { return }
        process = nil
        task.terminationHandler = nil
        if task.isRunning { task.terminate() }
    }

    func refresh() { Task { _ = await loadState() } }
    func reconnect() { action("reconnect", args: [:], label: "Reconnected") }
    func setMode(_ mode: String, announce: Bool) { action("set_mode", args: ["name": mode, "announce": announce], label: "Mode: \(mode)") }
    func setEqualizer(_ values: [Double]) { action("set_eq", args: ["bass": Int(values[safe: 0] ?? 0), "mid": Int(values[safe: 1] ?? 0), "treble": Int(values[safe: 2] ?? 0)], label: "Equalizer saved") }
    func setCNC(_ level: Int) { action("set_cnc", args: ["level": level], label: "Noise level: \(level)") }
    func setWind(_ enabled: Bool) { action("set_wind", args: ["enabled": enabled], label: "Wind block \(enabled ? "on" : "off")") }
    func setANC(_ enabled: Bool) { action("set_anc", args: ["enabled": enabled], label: "ANC \(enabled ? "on" : "off")") }
    func setSidetone(_ level: String) { action("set_sidetone", args: ["level": level], label: "Sidetone: \(level)") }
    func setPrompts(_ enabled: Bool) { action("set_prompts", args: ["enabled": enabled], label: "Voice prompts \(enabled ? "on" : "off")") }
    func setAutoPause(_ enabled: Bool) { action("set_auto_pause", args: ["enabled": enabled], label: "Auto-pause \(enabled ? "on" : "off")") }
    func setAutoAnswer(_ enabled: Bool) { action("set_auto_answer", args: ["enabled": enabled], label: "Auto-answer \(enabled ? "on" : "off")") }
    func rename(_ name: String) { action("set_name", args: ["new_name": name], label: "Renamed headphones") }
    func saveProfile(slot: Int, name: String, cnc: Int, wind: Bool, anc: Bool, spatial: Int) {
        action("set_profile", args: ["slot": slot, "name": name, "cnc_level": cnc, "wind_block": wind, "anc_toggle": anc, "spatial": spatial], label: "Saved profile slot \(slot)")
    }
    func deleteProfile(slot: Int) { action("delete_profile", args: ["slot": slot], label: "Cleared profile slot \(slot)") }
    func pair() { action("pair", args: [:], label: "Pairing mode enabled") }
    func powerOff() { action("power_off", args: [:], label: "Power off sent") }
    func clearRawLog() { rawLog = [] }

    func sendRaw(_ hex: String) {
        guard !hex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        rawLog.insert("TX  \(hex)", at: 0)
        Task {
            isBusy = true; defer { isBusy = false }
            do {
                let payload = try await post("send_raw", args: ["hex_str": hex])
                guard (payload["ok"] as? Bool) == true else { rawLog.insert("ERR \(string(payload["error"]))", at: 0); return }
                let responses = payload["result"] as? [[String: Any]] ?? []
                if responses.isEmpty { rawLog.insert("RX  (no response)", at: 0) }
                for response in responses.reversed() {
                    rawLog.insert("RX  [\(string(response["fblock"])).\(string(response["func"]))] op=\(string(response["op"])) \(string(response["payload"]))", at: 0)
                }
                if let snapshot = payload["state"] as? [String: Any] { apply(snapshot) }
            } catch { rawLog.insert("ERR Could not reach the Bluetooth service.", at: 0) }
        }
    }

    private func waitForBackend() async {
        for _ in 0..<16 {
            try? await Task.sleep(for: .milliseconds(350))
            if await loadState(silent: true) { return }
        }
        message = "Could not connect. Turn on and connect your headphones, then select Reconnect."
    }

    @discardableResult private func loadState(silent: Bool = false) async -> Bool {
        do {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/state")!); request.timeoutInterval = 15
            let (data, _) = try await URLSession.shared.data(for: request)
            let payload = try object(from: data)
            guard (payload["ok"] as? Bool) == true, let snapshot = payload["state"] as? [String: Any] else {
                if !silent { message = string(payload["error"]).isEmpty ? "Could not read headphones." : string(payload["error"]) }; return false
            }
            apply(snapshot); return true
        } catch { if !silent { message = "Could not reach the local Bluetooth service." }; return false }
    }

    private func action(_ name: String, args: [String: Any], label: String) {
        Task {
            isBusy = true; defer { isBusy = false }
            do {
                let payload = try await post(name, args: args)
                guard (payload["ok"] as? Bool) == true else { fail(label, error: string(payload["error"])); return }
                if let snapshot = payload["state"] as? [String: Any] { apply(snapshot) }
                message = "\(label) — verified by the headphones."
                writeLog.insert("✓ \(label)", at: 0)
            } catch { fail(label, error: "Could not reach the Bluetooth service.") }
        }
    }

    private func fail(_ label: String, error: String) { message = error; writeLog.insert("! \(label): \(error)", at: 0) }

    private func post(_ action: String, args: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/action")!)
        request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": action, "args": args])
        let (data, _) = try await URLSession.shared.data(for: request)
        return try object(from: data)
    }

    private func apply(_ snapshot: [String: Any]) {
        let status = snapshot["status"] as? [String: Any] ?? [:]
        let device = snapshot["device"] as? [String: Any] ?? [:]
        state.connected = true
        state.name = string(status["name"]).isEmpty ? string(device["name"]) : string(status["name"])
        if state.name.isEmpty { state.name = "Bose headphones" }
        state.model = string(device["name"]).isEmpty ? "Bose Headphones Control" : string(device["name"])
        state.battery = integer(status["battery"]); state.firmware = string(status["firmware"]).isEmpty ? "—" : string(status["firmware"])
        state.mode = string(status["mode"]).isEmpty ? "—" : string(status["mode"]); state.modeIndex = integer(status["mode_idx"])
        state.cncLevel = integer(status["cnc_level"]) ?? 0; state.cncMax = integer(status["cnc_max"]) ?? 10
        state.sidetone = string(status["sidetone"]).isEmpty ? "off" : string(status["sidetone"])
        state.promptsEnabled = (status["prompts_enabled"] as? Bool) ?? false; state.promptsLanguage = string(status["prompts_language"])
        state.autoPause = (status["auto_pause"] as? Bool) ?? false; state.autoAnswer = (status["auto_answer"] as? Bool) ?? false
        state.features = Set(snapshot["features"] as? [String] ?? [])
        state.profiles = (snapshot["profiles"] as? [[String: Any]] ?? []).compactMap { p in
            guard let slot = integer(p["mode_idx"]) else { return nil }
            return NativeProfile(id: slot, name: string(p["name"]), editable: (p["editable"] as? Bool) ?? false, configured: (p["configured"] as? Bool) ?? false, cncLevel: integer(p["cnc_level"]) ?? 0, windBlock: (p["wind_block"] as? Bool) ?? false, ancToggle: (p["anc_toggle"] as? Bool) ?? false, spatial: integer(p["spatial"]) ?? 0)
        }
        state.eq = (status["eq"] as? [[String: Any]] ?? []).map { Double(integer($0["current"]) ?? 0) }
        if state.eq.isEmpty { state.eq = [0, 0, 0] }
        state.buttons = (snapshot["buttons"] as? [[String: Any]] ?? []).enumerated().map { index, button in
            NativeButtonMapping(id: "\(integer(button["button_id"]) ?? index)-\(integer(button["event"]) ?? index)", button: string(button["button_name"]).isEmpty ? string(button["button_id"]) : string(button["button_name"]), event: string(button["event_name"]).isEmpty ? string(button["event"]) : string(button["event_name"]), action: string(button["action_name"]).isEmpty ? string(button["action"]) : string(button["action_name"]))
        }
        message = "Connected"
    }

    private func object(from data: Data) throws -> [String: Any] { guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NSError(domain: "BoseHeadphonesControl", code: 1) }; return value }
    private func string(_ value: Any?) -> String { value as? String ?? "" }
    private func integer(_ value: Any?) -> Int? { if let n = value as? NSNumber { return n.intValue }; if let s = value as? String { return Int(s) }; return nil }
}

private extension Array { subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }
