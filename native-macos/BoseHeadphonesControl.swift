import SwiftUI

@main
struct BoseHeadphonesControl: App {
    var body: some Scene {
        WindowGroup("Bose Headphones Control") {
            ControlPanel().frame(minWidth: 940, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

private struct ControlPanel: View {
    @StateObject private var backend = NativeBackend()
    @State private var bass = 0.0
    @State private var mid = 0.0
    @State private var treble = 0.0
    private let amber = Color(red: 0.96, green: 0.66, blue: 0.19)
    private let panel = Color(red: 0.075, green: 0.09, blue: 0.12)
    private let card = Color(red: 0.11, green: 0.13, blue: 0.17)

    var body: some View {
        ZStack {
            panel.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    statusCard
                    HStack(alignment: .top, spacing: 18) {
                        VStack(spacing: 18) { listeningModes; equalizer }
                        VStack(spacing: 18) { deviceCard; connectionCard }
                    }
                    Text(backend.message)
                        .font(.caption)
                        .foregroundStyle(backend.state.connected ? Color.secondary : Color.orange)
                }
                .padding(30)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { backend.start() }
        .onChange(of: backend.state.bass) { _, value in bass = value }
        .onChange(of: backend.state.mid) { _, value in mid = value }
        .onChange(of: backend.state.treble) { _, value in treble = value }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("BOSE HEADPHONES CONTROL")
                    .font(.system(size: 17, weight: .bold, design: .monospaced)).tracking(1.3)
                Text(backend.state.name).font(.title2.weight(.semibold))
            }
            Spacer()
            Label(backend.state.connected ? "CONNECTED" : "CONNECTING", systemImage: backend.state.connected ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(backend.state.connected ? Color.green : amber)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background((backend.state.connected ? Color.green : amber).opacity(0.12), in: Capsule())
        }
    }

    private var statusCard: some View {
        HStack(spacing: 28) {
            Image(systemName: "headphones").font(.system(size: 42, weight: .light)).foregroundStyle(amber)
            VStack(alignment: .leading, spacing: 6) {
                Text(backend.state.connected ? "Ready to listen" : "Waiting for headphones")
                    .font(.title3.weight(.semibold))
                Text(backend.state.connected ? "Connected over Bluetooth to this Mac." : "Turn on and connect your headphones, then select Reconnect.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(backend.state.battery.map { "\($0)%" } ?? "—")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Label("Battery", systemImage: "battery.75percent").foregroundStyle(.secondary)
            }
        }
        .padding(22).background(card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var listeningModes: some View {
        section("LISTENING MODE") {
            if backend.state.modes.isEmpty {
                Text("Modes appear when your headphones connect.").foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 10) {
                    ForEach(backend.state.modes, id: \.self) { mode in
                        Button(mode) { backend.setMode(mode) }
                            .buttonStyle(ModeButton(selected: mode.caseInsensitiveCompare(backend.state.mode) == .orderedSame, amber: amber))
                            .disabled(backend.isBusy)
                    }
                }
            }
            Text("Changes are read back from the headphones after every write.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var equalizer: some View {
        section("EQUALIZER") {
            EqSlider(title: "Bass", value: $bass, amber: amber)
            EqSlider(title: "Mid", value: $mid, amber: amber)
            EqSlider(title: "Treble", value: $treble, amber: amber)
            Button("Save equalizer") { backend.setEqualizer(bass: bass, mid: mid, treble: treble) }
                .buttonStyle(.borderedProminent).tint(amber).foregroundStyle(.black).disabled(backend.isBusy || !backend.state.connected)
        }
    }

    private var deviceCard: some View {
        section("DEVICE SETTINGS") {
            if backend.state.supportsSidetone {
                Picker("Sidetone", selection: Binding(get: { backend.state.sidetone }, set: backend.setSidetone)) {
                    Text("Off").tag("off"); Text("Low").tag("low"); Text("Medium").tag("medium"); Text("High").tag("high")
                }
                .disabled(backend.isBusy)
                Divider().overlay(.white.opacity(0.1))
            }
            if backend.state.supportsPrompts {
                Toggle(isOn: Binding(get: { backend.state.promptsEnabled }, set: backend.setPrompts)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Voice prompts")
                        Text("Announcements from your headphones")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(backend.isBusy)
                Divider().overlay(.white.opacity(0.1))
            }
            LabeledContent("Firmware", value: backend.state.firmware)
            LabeledContent("Current mode", value: backend.state.mode)
        }
    }

    private var connectionCard: some View {
        section("CONNECTION") {
            HStack {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(amber)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Bluetooth")
                    Text(backend.state.model).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reconnect") { backend.reconnect() }.buttonStyle(.bordered).tint(amber).disabled(backend.isBusy)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.system(size: 12, weight: .bold, design: .monospaced)).tracking(1.1).foregroundStyle(amber)
            content()
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading).background(card, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct ModeButton: ButtonStyle {
    let selected: Bool; let amber: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold)).padding(.horizontal, 15).padding(.vertical, 11)
            .foregroundStyle(selected ? Color.black : Color.primary)
            .background(selected ? amber : Color.white.opacity(configuration.isPressed ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct EqSlider: View {
    let title: String; @Binding var value: Double; let amber: Color
    var body: some View {
        HStack(spacing: 14) {
            Text(title).frame(width: 54, alignment: .leading)
            Slider(value: $value, in: -10...10, step: 1).tint(amber)
            Text(value, format: .number.sign(strategy: .always())).font(.system(.body, design: .monospaced)).frame(width: 28, alignment: .trailing).foregroundStyle(.secondary)
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing; line = max(line, size.height)
        }
        return CGSize(width: width, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size)); x += size.width + spacing; line = max(line, size.height)
        }
    }
}
