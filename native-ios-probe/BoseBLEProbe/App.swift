import SwiftUI

@main
struct BoseBLEProbeApp: App {
    @StateObject private var scanner = BLEScanner()

    var body: some Scene {
        WindowGroup {
            ContentView(scanner: scanner)
        }
    }
}
