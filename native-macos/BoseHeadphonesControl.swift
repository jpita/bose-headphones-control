import SwiftUI
import AppKit

#if SWIFT_BACKEND
private let backendFlavor = "SWIFT BACKEND"
private let menuBarConnectedIcon = "headphones.circle.fill"
private let menuBarDisconnectedIcon = "headphones.circle"
#else
private let backendFlavor = "PYTHON BACKEND"
private let menuBarConnectedIcon = "headphones"
private let menuBarDisconnectedIcon = "headphones.circle"
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NativeBackend.shared.start()
        DispatchQueue.main.async {
            FullWindowController.shared.show()
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        FullWindowController.shared.show()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { NativeBackend.shared.stop() }
}

@main struct BoseHeadphonesControl: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var backend = NativeBackend.shared

    var body: some Scene {
        MenuBarExtra {
            QuickPanel(backend: backend)
        } label: {
            Label(
                backend.state.battery.map { "Bose \($0)%" } ?? backendFlavor,
                systemImage: backend.state.connected ? menuBarConnectedIcon : menuBarDisconnectedIcon
            )
        }
        .menuBarExtraStyle(.window)
    }
}

private struct QuickPanel: View {
    @ObservedObject var backend: NativeBackend
    @Environment(\.dismiss) private var dismiss
    @AppStorage("announceMode") private var announceMode = false
    @State private var cncLevel = 0.0
    @State private var eq = [0.0, 0.0, 0.0]

    private let amber = Color(red: 0.96, green: 0.66, blue: 0.19)
    private let panel = Color(red: 0.055, green: 0.065, blue: 0.085)
    private let card = Color(red: 0.10, green: 0.12, blue: 0.15)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(backendFlavor)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(amber)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(amber.opacity(0.14), in: Capsule())

            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(amber.opacity(0.14))
                    Image(systemName: "headphones")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(amber)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(backend.state.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(backend.state.connected ? "CONNECTED" : "NOT CONNECTED")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(backend.state.connected ? .green : .secondary)
                }

                Spacer()

                Text(backend.state.battery.map { "\($0)%" } ?? "—")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
            }

            if backend.state.connected {
                quickControls
            } else {
                disconnectedCard
            }

            Divider().overlay(.white.opacity(0.08))

            Button {
                dismiss()
                DispatchQueue.main.async {
                    FullWindowController.shared.show()
                }
            } label: {
                Label("Open Full Window", systemImage: "rectangle.inset.filled")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(amber)
            .foregroundStyle(.black)

            HStack {
                Button("Reconnect") { backend.reconnect() }
                    .disabled(backend.isBusy)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 330)
        .background(panel)
        .preferredColorScheme(.dark)
        .onAppear {
            backend.start()
            cncLevel = Double(backend.state.cncLevel)
            eq = normalizedEQ(backend.state.eq)
        }
        .onChange(of: backend.state.cncLevel) { _, value in
            cncLevel = Double(value)
        }
        .onChange(of: backend.state.eq) { _, value in
            eq = normalizedEQ(value)
        }
    }

    private var quickControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !backend.state.playableProfiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    controlLabel("LISTENING MODE", value: backend.state.activeProfile?.name ?? backend.state.mode)
                    Picker("Listening mode", selection: Binding(
                        get: { backend.state.modeIndex ?? -1 },
                        set: { selectedID in
                            guard let profile = backend.state.playableProfiles.first(where: { $0.id == selectedID }) else { return }
                            backend.setMode(profile.name, announce: announceMode)
                        }
                    )) {
                        ForEach(backend.state.playableProfiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(backend.isBusy)
                }
            }

            if let profile = backend.state.activeProfile, profile.editable {
                VStack(alignment: .leading, spacing: 10) {
                    controlLabel("NOISE CONTROL", value: "\(backend.state.cncLevel) / \(backend.state.cncMax)")
                    Slider(
                        value: $cncLevel,
                        in: 0...Double(backend.state.cncMax),
                        step: 1
                    ) { editing in
                        if !editing { backend.setCNC(Int(cncLevel)) }
                    }
                    .tint(amber)
                    .disabled(backend.isBusy)

                    HStack {
                        Toggle("ANC", isOn: Binding(get: { profile.ancToggle }, set: backend.setANC))
                        Spacer()
                        Toggle("Wind block", isOn: Binding(get: { profile.windBlock }, set: backend.setWind))
                    }
                    .toggleStyle(.switch)
                    .disabled(backend.isBusy)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                controlLabel("EQUALIZER", value: eq.map { signed(Int($0)) }.joined(separator: " / "))
                ForEach(0..<3, id: \.self) { index in
                    HStack(spacing: 9) {
                        Text(["B", "M", "T"][index])
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                        Slider(value: $eq[index], in: -10...10, step: 1) { editing in
                            if !editing { backend.setEqualizer(eq) }
                        }
                        .tint(amber)
                        Text(signed(Int(eq[index])))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                    }
                }
            }
            .disabled(backend.isBusy)
        }
        .padding(14)
        .background(card, in: RoundedRectangle(cornerRadius: 14))
    }

    private var disconnectedCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Headphones unavailable")
                .font(.system(size: 13, weight: .semibold))
            Text("Connect them in macOS Bluetooth settings, then reconnect.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card, in: RoundedRectangle(cornerRadius: 14))
    }

    private func controlLabel(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(amber)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func normalizedEQ(_ values: [Double]) -> [Double] {
        Array(values.prefix(3)) + Array(repeating: 0, count: max(0, 3 - values.count))
    }

    private func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }
}

@MainActor
private final class FullWindowController {
    static let shared = FullWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Bose Headphones Control"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.minSize = NSSize(width: 940, height: 680)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: ControlPanel()
                    .frame(minWidth: 940, minHeight: 680)
                    .environment(\.controlActiveState, .active)
            )
            window.center()
            self.window = window
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ControlPanel: View {
    @StateObject private var backend = NativeBackend.shared
    @AppStorage("announceMode") private var announceMode = false
    @State private var eq = [0.0, 0.0, 0.0]
    @State private var deviceName = ""
    @State private var rawPacket = ""
    @State private var showPowerConfirm = false
    private let amber = Color(red: 0.96, green: 0.66, blue: 0.19)
    private let panel = Color(red: 0.075, green: 0.09, blue: 0.12)
    private let card = Color(red: 0.11, green: 0.13, blue: 0.17)

    var body: some View {
        ZStack { panel.ignoresSafeArea(); ScrollView { VStack(alignment: .leading, spacing: 18) {
            header; status; modes; noise; equalizer; profiles; settings; mappings; verification; rawConsole; actions
        }.padding(30) } }
        .preferredColorScheme(.dark).onAppear {
            backend.start()
            eq = Array(backend.state.eq.prefix(3)) + Array(repeating: 0, count: max(0, 3-backend.state.eq.count))
            deviceName = backend.state.name
        }
        .onChange(of: backend.state.eq) { _, v in eq = Array(v.prefix(3)) + Array(repeating: 0, count: max(0, 3-v.count)) }
        .onChange(of: backend.state.name) { _, v in deviceName = v }
        .confirmationDialog("Power off headphones?", isPresented: $showPowerConfirm, titleVisibility: .visible) { Button("Power off", role: .destructive) { backend.powerOff() } }
    }
    private var header: some View { HStack { VStack(alignment: .leading, spacing: 5) { Text(backendFlavor).font(.system(size:10,weight:.bold,design:.monospaced)).tracking(1).foregroundStyle(amber); Text("BOSE HEADPHONES CONTROL").font(.system(size:17,weight:.bold,design:.monospaced)).tracking(1.3); Text(backend.state.name).font(.title2.weight(.semibold)) }; Spacer(); Label(backend.state.connected ? "CONNECTED" : "CONNECTING", systemImage: backend.state.connected ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath").font(.system(size:13,weight:.bold,design:.monospaced)).foregroundStyle(backend.state.connected ? Color.green : amber).padding(.horizontal,12).padding(.vertical,8).background((backend.state.connected ? Color.green : amber).opacity(0.12), in: Capsule()); Button("Refresh") { backend.refresh() }.buttonStyle(.bordered).tint(amber); Button("Reconnect") { backend.reconnect() }.buttonStyle(.bordered).tint(amber).disabled(backend.isBusy) } }
    private var status: some View { HStack(spacing:28) { Image(systemName:"headphones").font(.system(size:42,weight:.light)).foregroundStyle(amber); VStack(alignment:.leading,spacing:6) { Text(backend.state.connected ? "Ready to listen" : "Waiting for headphones").font(.title3.weight(.semibold)); Text(backend.state.connected ? "Connected over Bluetooth to this Mac." : "Turn on and connect your headphones, then select Reconnect.").foregroundStyle(.secondary) }; Spacer(); VStack(alignment:.trailing,spacing:4) { Text(backend.state.battery.map { "\($0)%" } ?? "—").font(.system(size:30,weight:.bold,design:.rounded)); Label("Battery", systemImage:"battery.75percent").foregroundStyle(.secondary) } }.padding(22).background(card,in:RoundedRectangle(cornerRadius:18)) }
    private var modes: some View { section("LISTENING MODE") { FlowLayout(spacing:10) { ForEach(backend.state.playableProfiles) { p in Button(p.name) { backend.setMode(p.name, announce: announceMode) }.buttonStyle(ModeButton(selected:p.id == backend.state.modeIndex, amber:amber)).disabled(backend.isBusy) } }; Toggle("Say the mode name out loud", isOn:$announceMode).toggleStyle(.switch); if backend.state.playableProfiles.isEmpty { Text("Modes appear when the headphones connect.").foregroundStyle(.secondary) } } }
    private var noise: some View { Group { if let p = backend.state.activeProfile, p.editable { section("NOISE CONTROL") { Stepper("CNC level: \(backend.state.cncLevel)", value: Binding(get:{backend.state.cncLevel}, set:backend.setCNC), in:0...backend.state.cncMax).disabled(backend.isBusy); Toggle("ANC", isOn:Binding(get:{p.ancToggle}, set:backend.setANC)).toggleStyle(.switch).disabled(backend.isBusy); Toggle("Wind block", isOn:Binding(get:{p.windBlock}, set:backend.setWind)).toggleStyle(.switch).disabled(backend.isBusy); Text("0 is maximum noise cancellation; \(backend.state.cncMax) is maximum ambient sound.").font(.caption).foregroundStyle(.secondary) } } } }
    private var equalizer: some View { section("EQUALIZER") { ForEach(0..<3,id:\.self) { i in HStack { Text(["Bass","Mid","Treble"][i]).frame(width:58,alignment:.leading); Slider(value:$eq[i],in:-10...10,step:1).tint(amber); Text(eq[i],format:.number.sign(strategy:.always())).font(.system(.body,design:.monospaced)).frame(width:28) } }; HStack { Button("Flat") { eq = [0,0,0] }; Button("Bass boost") { eq = [4,0,2] }; Button("Podcast") { eq = [-4,2,3] }; Button("V-shape") { eq = [3,-2,4] }; Button("Restore −8/−2/0") { eq = [-8,-2,0] }; Button("Save equalizer") { backend.setEqualizer(eq) }.buttonStyle(.borderedProminent).tint(amber).foregroundStyle(.black) }.disabled(backend.isBusy || !backend.state.connected) } }
    private var profiles: some View { section("PROFILE SLOTS") { ForEach(backend.state.profiles) { profile in ProfileRow(profile:profile, maxCNC:backend.state.cncMax, active:profile.id == backend.state.modeIndex, backend:backend).id("\(profile.id)-\(profile.name)-\(profile.cncLevel)") } } }
    private var settings: some View { section("DEVICE SETTINGS") { HStack { TextField("Device name",text:$deviceName).textFieldStyle(.roundedBorder); Button("Rename") { backend.rename(deviceName) } }.disabled(backend.isBusy); if backend.state.supports("sidetone") { Picker("Sidetone",selection:Binding(get:{backend.state.sidetone},set:backend.setSidetone)) { ForEach(["off","low","medium","high"],id:\.self) { Text($0.capitalized).tag($0) } }.disabled(backend.isBusy) }; if backend.state.supports("voice_prompts") { Toggle("Voice prompts\(backend.state.promptsLanguage.isEmpty ? "" : " (\(backend.state.promptsLanguage))")",isOn:Binding(get:{backend.state.promptsEnabled},set:backend.setPrompts)).toggleStyle(.switch) }; if backend.state.supports("auto_pause") { Toggle("Pause when removed",isOn:Binding(get:{backend.state.autoPause},set:backend.setAutoPause)).toggleStyle(.switch) }; if backend.state.supports("auto_answer") { Toggle("Auto-answer calls",isOn:Binding(get:{backend.state.autoAnswer},set:backend.setAutoAnswer)).toggleStyle(.switch) }; Divider().overlay(.white.opacity(0.1)); LabeledContent("Firmware",value:backend.state.firmware); LabeledContent("Current mode",value:backend.state.mode) } }
    private var mappings: some View { section("BUTTON MAPPING") { if backend.state.buttons.isEmpty { Text("This device reports no remappable buttons.").foregroundStyle(.secondary) } else { Grid(alignment:.leading,horizontalSpacing:24,verticalSpacing:8) { GridRow { Text("BUTTON").foregroundStyle(.secondary); Text("EVENT").foregroundStyle(.secondary); Text("DOES").foregroundStyle(.secondary) }; ForEach(backend.state.buttons) { b in GridRow { Text(b.button); Text(b.event).font(.system(.body,design:.monospaced)); Text(b.action).font(.system(.body,design:.monospaced)) } } }; Text("Read-only, matching the Electron app. Use the Bose app to remap buttons.").font(.caption).foregroundStyle(.secondary) } } }
    private var verification: some View { section("WRITE VERIFICATION") { if backend.writeLog.isEmpty { Text("Every change is read back from the headphones.").foregroundStyle(.secondary) } else { ForEach(backend.writeLog,id:\.self) { Text($0).font(.system(.caption,design:.monospaced)).foregroundStyle($0.hasPrefix("!") ? .orange : .green) } } } }
    private var rawConsole: some View { section("RAW BMAP CONSOLE") { Text("Packet: <fblock> <func> <op> <len> <payload>. Example: 02 02 01 00").font(.caption).foregroundStyle(.secondary); HStack { TextField("02 02 01 00",text:$rawPacket).textFieldStyle(.roundedBorder); Button("Send") { backend.sendRaw(rawPacket) }; Button("Clear") { backend.clearRawLog() } }; ForEach(backend.rawLog,id:\.self) { Text($0).font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary) } } }
    private var actions: some View { section("DEVICE ACTIONS") { HStack { Button("Enter pairing mode") { backend.pair() }; Button("Power off headphones",role:.destructive) { showPowerConfirm = true } }.disabled(backend.isBusy); Text(backend.message).font(.caption).foregroundStyle(backend.state.connected ? Color.secondary : Color.orange) } }
    private func section<Content:View>(_ title:String,@ViewBuilder content:()->Content)->some View { VStack(alignment:.leading,spacing:16) { Text(title).font(.system(size:12,weight:.bold,design:.monospaced)).tracking(1.1).foregroundStyle(amber); content() }.padding(22).frame(maxWidth:.infinity,alignment:.leading).background(card,in:RoundedRectangle(cornerRadius:18)) }
}
private struct ProfileRow: View { let profile:NativeProfile; let maxCNC:Int; let active:Bool; @ObservedObject var backend:NativeBackend; @State private var name=""; @State private var cnc=0; @State private var wind=false; @State private var anc=false; init(profile:NativeProfile,maxCNC:Int,active:Bool,backend:NativeBackend){self.profile=profile;self.maxCNC=maxCNC;self.active=active;self.backend=backend;_name=State(initialValue:profile.name);_cnc=State(initialValue:profile.cncLevel);_wind=State(initialValue:profile.windBlock);_anc=State(initialValue:profile.ancToggle)}; var body:some View { VStack(alignment:.leading,spacing:8) { HStack { Text("\(profile.id)").font(.system(.body,design:.monospaced)).foregroundStyle(.secondary); Text(profile.name.isEmpty ? "Empty slot" : profile.name).fontWeight(.semibold); Spacer(); if active { Text("ACTIVE").font(.caption).foregroundStyle(.orange) }; if !profile.editable { Text("PRESET").font(.caption).foregroundStyle(.secondary) } }; if profile.editable { HStack { TextField("Profile name",text:$name).textFieldStyle(.roundedBorder); Stepper("CNC \(cnc)",value:$cnc,in:0...maxCNC); Toggle("Wind",isOn:$wind).toggleStyle(.switch); Toggle("ANC",isOn:$anc).toggleStyle(.switch); Button(profile.name.isEmpty ? "Create":"Save") { backend.saveProfile(slot:profile.id,name:name.trimmingCharacters(in:.whitespacesAndNewlines),cnc:cnc,wind:wind,anc:anc,spatial:profile.spatial) }; if !profile.name.isEmpty { Button("Clear",role:.destructive) { backend.deleteProfile(slot:profile.id) } } } } else if !active { Button("Activate") { backend.setMode(profile.name,announce:false) } } }.padding(12).background(Color.white.opacity(0.045),in:RoundedRectangle(cornerRadius:10)) } }
private struct ModeButton:ButtonStyle { let selected:Bool;let amber:Color;func makeBody(configuration:Configuration)->some View { configuration.label.padding(.horizontal,15).padding(.vertical,11).foregroundStyle(selected ? Color.black:Color.primary).background(selected ? amber:Color.white.opacity(0.06),in:RoundedRectangle(cornerRadius:10)) } }
private struct FlowLayout:Layout { var spacing:CGFloat=8; func sizeThatFits(proposal:ProposedViewSize,subviews:Subviews,cache:inout())->CGSize{let w=proposal.width ?? 400;var x:CGFloat=0,y:CGFloat=0,l:CGFloat=0;for v in subviews{let s=v.sizeThatFits(.unspecified);if x+s.width>w,x>0{x=0;y+=l+spacing;l=0};x+=s.width+spacing;l=max(l,s.height)};return CGSize(width:w,height:y+l)};func placeSubviews(in b:CGRect,proposal:ProposedViewSize,subviews:Subviews,cache:inout()){var x=b.minX,y=b.minY,l:CGFloat=0;for v in subviews{let s=v.sizeThatFits(.unspecified);if x+s.width>b.maxX,x>b.minX{x=b.minX;y+=l+spacing;l=0};v.place(at:CGPoint(x:x,y:y),proposal:ProposedViewSize(s));x+=s.width+spacing;l=max(l,s.height)}} }
