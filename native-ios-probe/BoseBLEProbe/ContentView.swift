import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var scanner: BLEScanner

    private let amber = Color(red: 0.96, green: 0.66, blue: 0.19)
    private let panel = Color(red: 0.055, green: 0.065, blue: 0.085)
    private let card = Color(red: 0.10, green: 0.12, blue: 0.15)

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusCard
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section("NEARBY BLE DEVICES") {
                    if scanner.devices.isEmpty {
                        Text("No advertisements yet. Keep the QC45 powered on and nearby.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(scanner.devices) { device in
                        deviceRow(device)
                    }
                }

                if !scanner.characteristics.isEmpty {
                    Section("DISCOVERED CHARACTERISTICS") {
                        ForEach(scanner.characteristics) { characteristic in
                            characteristicRow(characteristic)
                        }
                    }
                }

                Section("PROBE LOG") {
                    Button("Copy report") {
                        UIPasteboard.general.string = scanner.report
                    }
                    .foregroundStyle(amber)

                    ForEach(Array(scanner.log.prefix(30).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(panel)
            .navigationTitle("Bose BLE Probe")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(scanner.isScanning ? "Stop" : "Scan") {
                        scanner.isScanning ? scanner.stopScanning() : scanner.startScanning()
                    }
                }
            }
        }
        .tint(amber)
        .preferredColorScheme(.dark)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("READ-ONLY DIAGNOSTIC", systemImage: "shield.lefthalf.filled")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(amber)
            Text(scanner.connectedName ?? (scanner.isScanning ? "Looking for Bose BLE…" : "Not scanning"))
                .font(.title3.weight(.semibold))
            Text("Bluetooth: \(scanner.bluetoothState). Status test sends GET requests only; it never changes settings, pairing, or audio routing.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if scanner.bmapAvailable {
                Button("Read Bose status") { scanner.readBoseStatus() }
                    .buttonStyle(.borderedProminent)
                Text(scanner.bmapStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if scanner.bmapVersion != nil || scanner.battery != nil || scanner.currentMode != nil {
                    HStack(spacing: 14) {
                        metric("BMAP", scanner.bmapVersion ?? "—")
                        metric("BATTERY", scanner.battery.map { "\($0)%" } ?? "—")
                        metric("MODE", scanner.currentMode.map(String.init) ?? "—")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .semibold, design: .monospaced))
        }
    }

    private func deviceRow(_ device: ProbeDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: device.isLikelyBose ? "headphones.circle.fill" : "antenna.radiowaves.left.and.right")
                .foregroundStyle(device.isLikelyBose ? amber : .secondary)
                .font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name).fontWeight(device.isLikelyBose ? .semibold : .regular)
                Text("RSSI \(device.rssi) · \(device.connection)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if device.connection != "Connected" {
                Button("Connect") { scanner.connect(to: device.id) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func characteristicRow(_ characteristic: ProbeCharacteristic) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(characteristic.uuid).font(.caption.monospaced().weight(.semibold))
                    Text("Service \(characteristic.service)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if characteristic.properties.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains("read") {
                    Button("Read") { scanner.read(characteristic.id) }
                        .buttonStyle(.bordered)
                }
            }
            Text(characteristic.properties)
                .font(.caption2.monospaced())
                .foregroundStyle(amber)
            if let value = characteristic.value {
                Text(value)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }
}
