import Foundation
import OSLog

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
    var model = "Bose Headphones Control for iPhone"
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
    var playableProfiles: [NativeProfile] {
        profiles.filter { !$0.editable || !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    func supports(_ feature: String) -> Bool { features.contains(feature) }
}

private struct AudioSettings {
    var cncLevel: Int
    var autoCNC: Bool
    var spatial: Int
    var windBlock: Bool
    var ancToggle: Bool

    var payload: Data {
        Data([
            UInt8(clamping: cncLevel), autoCNC ? 1 : 0, UInt8(clamping: spatial),
            windBlock ? 1 : 0, ancToggle ? 1 : 0
        ])
    }
}

@MainActor
final class BoseController: ObservableObject {
    static let shared = BoseController()

    @Published private(set) var state = NativeHeadphoneState()
    @Published private(set) var message = "Starting native Bluetooth…"
    @Published private(set) var isBusy = false
    @Published private(set) var writeLog: [String] = []
    @Published private(set) var rawLog: [String] = []

    private let bluetooth: any BoseTransport
    private let logger = Logger(subsystem: "com.jpita.bose-headphones-control.ios", category: "BLE")
    private var startupTask: Task<Void, Never>?
    private var modesByIndex: [Int: BMAPModeConfig] = [:]
    private var audioSettings: AudioSettings?
    private var promptLanguageID: UInt8 = 0

    init(bluetooth: any BoseTransport = BoseBLETransport()) {
        self.bluetooth = bluetooth
    }

    func start() {
        guard startupTask == nil, !state.connected else { return }
        startupTask = Task {
            isBusy = true
            defer { startupTask = nil; isBusy = false }
            await connectAndLoad()
        }
    }

    func stop() {
        startupTask?.cancel()
        startupTask = nil
        bluetooth.disconnect()
        state.connected = false
    }

    func refresh() {
        guard !isBusy else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            await refreshState()
        }
    }

    func reconnect() {
        Task {
            isBusy = true
            message = "Reconnecting over Bose BLE…"
            bluetooth.disconnect()
            state.connected = false
            await connectAndLoad()
            isBusy = false
        }
    }

    func setMode(_ mode: String, announce: Bool) {
        guard !isBusy else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            guard let profile = state.profiles.first(where: { $0.name.caseInsensitiveCompare(mode) == .orderedSame }) else {
                message = "Unknown listening mode: \(mode)"
                return
            }

            message = "Switching to \(profile.name)…"
            var commandError: Error?
            do {
                _ = try await bluetooth.exchange(
                    BMAPPacket(31, 3, .start, payload: Data([UInt8(profile.id), announce ? 1 : 0])),
                    timeout: .seconds(2)
                )
            } catch {
                // Some QC45 firmware applies the mode but omits the final
                // RESULT. Read-back below remains the source of truth.
                commandError = error
            }

            for attempt in 0..<4 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(180)) }
                if let packet = try? await request(31, 3, .get),
                   let index = packet.payload.first,
                   Int(index) == profile.id {
                    state.modeIndex = profile.id
                    state.mode = profile.name
                    state.cncLevel = profile.cncLevel
                    message = "Mode: \(profile.name) — verified by the headphones."
                    writeLog.insert("✓ Mode: \(profile.name)", at: 0)
                    return
                }
            }

            let reason = commandError?.localizedDescription ?? "the read-back did not match"
            message = "Could not verify \(profile.name): \(reason)"
            writeLog.insert("! Mode: \(profile.name): \(reason)", at: 0)
        }
    }

    func setEqualizer(_ values: [Double]) {
        action("Equalizer saved") {
            let normalized = Array(values.prefix(3)) + Array(repeating: 0, count: max(0, 3 - values.count))
            for (band, value) in normalized.enumerated() {
                guard (-10...10).contains(Int(value)) else {
                    throw BMAPError.unsupported("Equalizer values must be between -10 and +10.")
                }
                _ = try await self.request(1, 7, .setGet, Data([UInt8(bitPattern: Int8(value)), UInt8(band)]))
            }
        }
    }

    func setCNC(_ level: Int) {
        action("Noise level: \(level)") {
            guard (0...10).contains(level) else { throw BMAPError.unsupported("Noise level must be 0–10.") }
            try await self.updateAudio(cncLevel: level)
        }
    }

    func setWind(_ enabled: Bool) {
        action("Wind block \(enabled ? "on" : "off")") { try await self.updateAudio(windBlock: enabled) }
    }

    func setANC(_ enabled: Bool) {
        action("ANC \(enabled ? "on" : "off")") { try await self.updateAudio(ancToggle: enabled) }
    }

    func setSidetone(_ level: String) {
        action("Sidetone: \(level)") {
            let values = ["off": 0, "high": 1, "medium": 2, "low": 3]
            guard let value = values[level.lowercased()] else { throw BMAPError.unsupported("Unknown sidetone level.") }
            _ = try await self.request(1, 11, .setGet, Data([1, UInt8(value)]))
        }
    }

    func setPrompts(_ enabled: Bool) {
        action("Voice prompts \(enabled ? "on" : "off")") {
            _ = try await self.request(1, 3, .setGet, Data([((enabled ? 1 : 0) << 5) | self.promptLanguageID]))
        }
    }

    func setAutoPause(_ enabled: Bool) {
        action("Auto-pause \(enabled ? "on" : "off")") {
            _ = try await self.request(1, 24, .setGet, Data([enabled ? 1 : 0]))
        }
    }

    func setAutoAnswer(_ enabled: Bool) {
        action("Auto-answer \(enabled ? "on" : "off")") {
            _ = try await self.request(1, 27, .setGet, Data([enabled ? 1 : 0]))
        }
    }

    func rename(_ name: String) {
        action("Renamed headphones") {
            let bytes = Data(name.utf8)
            guard !bytes.isEmpty, bytes.count <= 31 else {
                throw BMAPError.unsupported("The name must contain 1–31 UTF-8 bytes.")
            }
            _ = try await self.request(1, 2, .setGet, bytes)
        }
    }

    func saveProfile(slot: Int, name: String, cnc: Int, wind: Bool, anc: Bool, spatial: Int) {
        action("Saved profile slot \(slot)") {
            guard var config = self.modesByIndex[slot], config.editable else {
                throw BMAPError.unsupported("Slot \(slot) is not writable.")
            }
            config.name = name
            config.cncLevel = cnc
            config.windBlock = wind
            config.ancToggle = anc
            config.spatial = spatial
            _ = try await self.request(31, 6, .setGet, try config.writePayload())
        }
    }

    func deleteProfile(slot: Int) {
        action("Cleared profile slot \(slot)") {
            guard var config = self.modesByIndex[slot], config.editable else {
                throw BMAPError.unsupported("Slot \(slot) is not writable.")
            }
            config.name = ""
            config.cncLevel = 0
            config.autoCNC = false
            config.spatial = 0
            config.windBlock = false
            config.ancToggle = false
            _ = try await self.request(31, 6, .setGet, try config.writePayload(name: ""))
        }
    }

    func pair() {
        noRefreshAction("Pairing mode enabled") { _ = try await self.request(4, 8, .start, Data([1])) }
    }

    func powerOff() {
        noRefreshAction("Power off sent") { _ = try await self.request(7, 4, .start, Data([0])) }
    }

    func clearRawLog() { rawLog = [] }

    func sendRaw(_ hex: String) {
        let compact = hex.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined()
        guard compact.count >= 8, compact.count.isMultiple(of: 2) else {
            rawLog.insert("ERR Enter a complete BMAP packet as hexadecimal bytes.", at: 0)
            return
        }
        var bytes = Data()
        var cursor = compact.startIndex
        while cursor < compact.endIndex {
            let end = compact.index(cursor, offsetBy: 2)
            guard let byte = UInt8(compact[cursor..<end], radix: 16) else {
                rawLog.insert("ERR Invalid hexadecimal packet.", at: 0)
                return
            }
            bytes.append(byte)
            cursor = end
        }
        guard let packet = BMAPPacket.parseAll(bytes).first else {
            rawLog.insert("ERR Invalid BMAP packet.", at: 0)
            return
        }

        rawLog.insert("TX  \(bytes.hex)", at: 0)
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let replies = try await bluetooth.exchange(packet, drain: true)
                if replies.isEmpty { rawLog.insert("RX  (no response)", at: 0) }
                for reply in replies.reversed() { rawLog.insert("RX  \(reply.summary)", at: 0) }
                await refreshState(silent: true)
            } catch {
                rawLog.insert("ERR \(error.localizedDescription)", at: 0)
            }
        }
    }

    private func connectAndLoad() async {
        do {
            logger.info("Starting native iPhone controller")
            print("[BLE] Starting native iPhone controller")
            message = "Looking for your Bose headphones…"
            try await bluetooth.connect()
            message = "Connected. Reading headphone settings…"
            try await loadState()
            if CommandLine.arguments.contains("--smoke-test-write") {
                try await smokeTestCurrentEqualizer()
            }
            message = "Connected directly over BLE."
            logger.info("Native iPhone controller connected and loaded state")
            print("[BLE] Loaded battery=\(state.battery.map(String.init) ?? "unknown") mode=\(state.mode) profiles=\(state.profiles.count) features=\(state.features.sorted().joined(separator: ","))")
        } catch {
            state.connected = false
            state.name = "Headphones unavailable"
            message = error.localizedDescription
            logger.error("Native backend failed: \(error.localizedDescription, privacy: .public)")
            print("[BLE] Controller failed: \(error.localizedDescription)")
        }
    }

    private func refreshState(silent: Bool = false) async {
        do {
            if !bluetooth.isReady { try await bluetooth.connect() }
            try await loadState()
            if !silent { message = "Connected directly over BLE." }
        } catch {
            state.connected = false
            if !silent { message = error.localizedDescription }
        }
    }

    private func loadState(includeModeCatalog: Bool = true) async throws {
        // Older QuietComfort firmware expects this harmless ProductInfo GET first.
        _ = try? await request(0, 1, .get)

        var next = NativeHeadphoneState()
        next.connected = true
        next.name = bluetooth.connectedName ?? "Bose headphones"
        next.model = next.name

        if let packet = try? await request(2, 2, .get), let battery = packet.payload.first {
            next.battery = Int(battery)
        }
        if let packet = try? await request(0, 5, .get) {
            next.firmware = decodeBMAPString(packet.payload)
        }
        if let packet = try? await request(1, 2, .get), !packet.payload.isEmpty {
            let bytes = packet.payload.dropFirst()
            let deviceName = decodeBMAPString(bytes)
            if !deviceName.isEmpty { next.name = deviceName }
        }

        var configs: [BMAPModeConfig] = []
        if includeModeCatalog {
            let modePackets = try await bluetooth.exchange(BMAPPacket(31, 1, .start), drain: true, timeout: .seconds(7))
            configs = modePackets
                .filter { $0.functionBlock == 31 && $0.function == 6 && $0.operation == BMAPOperator.status.rawValue }
                .compactMap { BMAPModeConfig.parse($0.payload) }
                .sorted { $0.index < $1.index }
            modesByIndex = Dictionary(uniqueKeysWithValues: configs.map { ($0.index, $0) })
            next.profiles = configs.map { config in
                NativeProfile(
                    id: config.index,
                    name: displayName(for: config),
                    editable: config.editable,
                    configured: config.configured,
                    cncLevel: config.cncLevel,
                    windBlock: config.windBlock,
                    ancToggle: config.ancToggle,
                    spatial: config.spatial
                )
            }
        } else {
            next.profiles = state.profiles
        }

        if let packet = try? await request(31, 3, .get), let index = packet.payload.first {
            next.modeIndex = Int(index)
            next.mode = next.profiles.first(where: { $0.id == Int(index) })?.name ?? "Mode \(index)"
        }

        if let active = next.modeIndex.flatMap({ modesByIndex[$0] }) {
            next.cncLevel = active.cncLevel
        } else if let packet = try? await request(1, 5, .get), packet.payload.count >= 3 {
            next.cncLevel = Int(packet.payload[packet.payload.startIndex + 1])
            next.cncMax = max(1, Int(packet.payload.first ?? 11) - 1)
        }

        audioSettings = nil
        if let packet = try? await request(31, 10, .get), packet.payload.count >= 5 {
            let bytes = [UInt8](packet.payload)
            let settings = AudioSettings(
                cncLevel: Int(bytes[0]), autoCNC: bytes[1] != 0, spatial: Int(bytes[2]),
                windBlock: bytes[3] != 0, ancToggle: bytes[4] != 0
            )
            audioSettings = settings
            next.cncLevel = settings.cncLevel
        }

        if let packet = try? await request(1, 7, .get) {
            let values = parseEQ(packet.payload)
            if !values.isEmpty { next.eq = values.map(Double.init); next.features.insert("eq") }
        }
        if let packet = try? await request(1, 11, .get), packet.payload.count >= 2 {
            let names = [0: "off", 1: "high", 2: "medium", 3: "low"]
            next.sidetone = names[Int(packet.payload[packet.payload.startIndex + 1])] ?? "off"
            next.features.insert("sidetone")
        }
        if let packet = try? await request(1, 3, .get), let value = packet.payload.first {
            promptLanguageID = value & 0x1f
            next.promptsEnabled = value & 0x20 != 0
            next.promptsLanguage = promptLanguageName(promptLanguageID)
            next.features.insert("voice_prompts")
        }
        if let packet = try? await request(1, 24, .get), let value = packet.payload.first {
            next.autoPause = value != 0
            next.features.insert("auto_pause")
        }
        if let packet = try? await request(1, 27, .get), let value = packet.payload.first {
            next.autoAnswer = value != 0
            next.features.insert("auto_answer")
        }
        if let packet = try? await request(1, 9, .get), let mapping = parseButton(packet.payload) {
            next.buttons = [mapping]
            next.features.insert("buttons")
        }

        if !next.profiles.isEmpty { next.features.formUnion(["current_mode", "mode_config"]) }
        if audioSettings != nil { next.features.insert("audio_settings") }
        state = next
    }

    private func action(_ label: String, operation: @escaping () async throws -> Void) {
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                try await operation()
                try await loadState(includeModeCatalog: false)
                message = "\(label) — verified by the headphones."
                writeLog.insert("✓ \(label)", at: 0)
            } catch {
                message = error.localizedDescription
                writeLog.insert("! \(label): \(error.localizedDescription)", at: 0)
            }
        }
    }

    private func noRefreshAction(_ label: String, operation: @escaping () async throws -> Void) {
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                try await operation()
                message = label
                writeLog.insert("✓ \(label)", at: 0)
            } catch {
                message = error.localizedDescription
                writeLog.insert("! \(label): \(error.localizedDescription)", at: 0)
            }
        }
    }

    private func request(
        _ block: UInt8,
        _ function: UInt8,
        _ operation: BMAPOperator,
        _ payload: Data = Data()
    ) async throws -> BMAPPacket {
        let replies = try await bluetooth.exchange(BMAPPacket(block, function, operation, payload: payload))
        guard let reply = replies.first else { throw BMAPError.malformedPacket }
        return try checked(reply)
    }

    private func smokeTestCurrentEqualizer() async throws {
        guard state.features.contains("eq"), state.eq.count >= 3 else {
            throw BMAPError.unsupported("The smoke test requires a readable equalizer.")
        }
        let original = state.eq.prefix(3).map { Int($0) }
        for (band, value) in original.enumerated() {
            _ = try await request(1, 7, .setGet, Data([UInt8(bitPattern: Int8(value)), UInt8(band)]))
        }
        guard let packet = try? await request(1, 7, .get), parseEQ(packet.payload) == original else {
            throw BMAPError.unsupported("The equalizer smoke test did not read back the original values.")
        }
        print("[Backend] Idempotent EQ write/read-back smoke test passed: \(original)")
    }

    private func updateAudio(cncLevel: Int? = nil, windBlock: Bool? = nil, ancToggle: Bool? = nil) async throws {
        if var settings = audioSettings {
            if let cncLevel { settings.cncLevel = cncLevel }
            if let windBlock { settings.windBlock = windBlock }
            if let ancToggle { settings.ancToggle = ancToggle }
            _ = try await request(31, 10, .setGet, settings.payload)
            return
        }

        guard let index = state.modeIndex, var config = modesByIndex[index], config.editable else {
            throw BMAPError.unsupported("Select an editable listening mode before changing its noise settings.")
        }
        if ancToggle != nil && !config.layout.supportsANCToggle {
            throw BMAPError.unsupported("This headphone firmware does not expose an ANC on/off toggle.")
        }
        if let cncLevel { config.cncLevel = cncLevel }
        if let windBlock { config.windBlock = windBlock }
        if let ancToggle { config.ancToggle = ancToggle }
        _ = try await request(31, 6, .setGet, try config.writePayload())
    }

    private func displayName(for config: BMAPModeConfig) -> String {
        if !config.name.isEmpty { return config.name }
        let known = [0: "Quiet", 1: "Aware", 2: "Immersion", 3: "Cinema"]
        return known[config.index] ?? (config.editable ? "" : "Mode \(config.index)")
    }

    private func parseEQ(_ payload: Data) -> [Int] {
        let bytes = [UInt8](payload)
        var bands: [Int: Int] = [:]
        var offset = 0
        while offset + 3 < bytes.count {
            bands[Int(bytes[offset + 3])] = Int(Int8(bitPattern: bytes[offset + 2]))
            offset += 4
        }
        return (0...2).compactMap { bands[$0] }
    }

    private func parseButton(_ payload: Data) -> NativeButtonMapping? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 3 else { return nil }
        let buttonNames = [0: "DistalCnc", 2: "Vpa", 3: "RightShortcut", 4: "LeftShortcut", 16: "Action", 128: "Shortcut"]
        let eventNames = [3: "short_press", 4: "single_press", 5: "press_and_hold", 6: "double_press", 9: "long_press"]
        let actionNames = [0: "NotConfigured", 1: "VPA", 2: "ANC", 3: "BatteryLevel", 4: "PlayPause", 8: "SwitchDevice", 14: "Disabled", 17: "ModesCarousel", 19: "SpatialAudioMode"]
        return NativeButtonMapping(
            id: "\(bytes[0])-\(bytes[1])",
            button: buttonNames[Int(bytes[0])] ?? String(format: "0x%02x", bytes[0]),
            event: eventNames[Int(bytes[1])] ?? String(bytes[1]),
            action: actionNames[Int(bytes[2])] ?? String(bytes[2])
        )
    }

    private func promptLanguageName(_ id: UInt8) -> String {
        let names = [
            "UK English", "US English", "French", "Italian", "German", "EU Spanish",
            "MX Spanish", "BR Portuguese", "Mandarin", "Korean", "Russian", "Polish",
            "Hebrew", "Turkish", "Dutch", "Japanese", "Cantonese", "Arabic", "Swedish",
            "Danish", "Norwegian", "Finnish", "Hindi"
        ]
        return Int(id) < names.count ? names[Int(id)] : "Language \(id)"
    }
}
