import SwiftUI
import UIKit

@main
struct BoseHeadphonesControlApp: App {
    @StateObject private var controller = BoseController.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .onAppear { updateIdleTimer() }
                .onChange(of: scenePhase) { _, _ in updateIdleTimer() }
                .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
                    updateIdleTimer()
                }
        }
    }

    private func updateIdleTimer() {
        let batteryState = UIDevice.current.batteryState
        let isCharging = batteryState == .charging || batteryState == .full
        UIApplication.shared.isIdleTimerDisabled = scenePhase == .active && isCharging
    }
}
