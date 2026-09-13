import Foundation
import IOBluetooth
import OSLog

enum BoseRFCOMMError: LocalizedError {
    case noHeadphones
    case connectionFailed(String)
    case notConnected
    case busy
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .noHeadphones: return "No paired Bose headphones were found."
        case let .connectionFailed(reason): return "Could not open the Bose Bluetooth channel: \(reason)"
        case .notConnected: return "The headphones are not connected."
        case .busy: return "Another Bluetooth command is still running."
        case let .timeout(operation): return "Timed out while \(operation)."
        }
    }
}

@MainActor
final class BoseRFCOMMClient: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private let logger = Logger(subsystem: "com.jpita.bose-headphones-control.swift", category: "Bluetooth")
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var incoming = Data()
    private var pending: PendingExchange?

    private struct PendingExchange {
        let id: UUID
        let expectedBlock: UInt8
        let expectedFunction: UInt8
        let drain: Bool
        var packets: [BMAPPacket]
        let continuation: CheckedContinuation<[BMAPPacket], Error>
        var quietTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
    }

    var connectedName: String? { device?.name }
    var isReady: Bool { channel?.isOpen() == true }

    func connect() async throws {
        if isReady { return }
        close()

        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let candidates = paired.filter { candidate in
            let name = candidate.name ?? ""
            return name.localizedCaseInsensitiveContains("bose")
                || name.localizedCaseInsensitiveContains("qc 45")
                || name.localizedCaseInsensitiveContains("quietcomfort")
        }.sorted { $0.isConnected() && !$1.isConnected() }

        guard let selected = candidates.first else { throw BoseRFCOMMError.noHeadphones }
        device = selected
        logger.info("Opening native Swift RFCOMM transport")
        print("[Bluetooth] Opening RFCOMM for \(selected.name ?? "Bose headphones")")

        _ = selected.performSDPQuery(nil)
        if !selected.isConnected() {
            let status = selected.openConnection()
            guard status == kIOReturnSuccess else {
                throw BoseRFCOMMError.connectionFailed("baseband status \(status)")
            }
        }

        let deviceName = (selected.name ?? "").lowercased()
        let preferred: BluetoothRFCOMMChannelID = deviceName.contains("qc 45")
            || deviceName.contains("quietcomfort 35") ? 8 : 2
        let channels: [BluetoothRFCOMMChannelID] = [preferred, 2, 8, 9].reduce(into: []) {
            if !$0.contains($1) { $0.append($1) }
        }

        var errors: [String] = []
        for channelID in channels {
            var opened: IOBluetoothRFCOMMChannel?
            let status = selected.openRFCOMMChannelSync(&opened, withChannelID: channelID, delegate: self)
            if status == kIOReturnSuccess, let opened {
                channel = opened
                incoming.removeAll(keepingCapacity: true)
                logger.info("RFCOMM channel \(channelID) ready")
                print("[Bluetooth] RFCOMM channel \(channelID) ready")
                return
            }
            errors.append("\(channelID)=\(status)")
        }
        throw BoseRFCOMMError.connectionFailed("channels \(errors.joined(separator: ", "))")
    }

    func disconnect() { close() }

    func exchange(_ packet: BMAPPacket, drain: Bool = false, timeout: Duration = .seconds(5)) async throws -> [BMAPPacket] {
        guard let channel, channel.isOpen() else { throw BoseRFCOMMError.notConnected }
        guard pending == nil else { throw BoseRFCOMMError.busy }

        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            var request = PendingExchange(
                id: id,
                expectedBlock: packet.functionBlock,
                expectedFunction: packet.function,
                drain: drain,
                packets: [],
                continuation: continuation
            )
            request.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finishPending(id: id, result: .failure(BoseRFCOMMError.timeout("waiting for BMAP [\(packet.functionBlock).\(packet.function)]")))
            }
            pending = request

            var bytes = [UInt8](packet.data)
            let status = channel.writeSync(&bytes, length: UInt16(bytes.count))
            if status != kIOReturnSuccess {
                finishPending(id: id, result: .failure(BoseRFCOMMError.connectionFailed("write status \(status)")))
            }
        }
    }

    nonisolated func rfcommChannelData(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        data dataPointer: UnsafeMutableRawPointer!,
        length dataLength: Int
    ) {
        guard let dataPointer, dataLength > 0 else { return }
        let bytes = Data(bytes: dataPointer, count: dataLength)
        Task { @MainActor in
            incoming.append(bytes)
            consumePackets()
        }
    }

    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        Task { @MainActor in
            channel = nil
            failPending(BoseRFCOMMError.notConnected)
        }
    }

    private func consumePackets() {
        while incoming.count >= 4 {
            let length = Int(incoming[incoming.startIndex + 3])
            let packetLength = 4 + length
            guard incoming.count >= packetLength else { return }
            let bytes = Data(incoming.prefix(packetLength))
            incoming.removeFirst(packetLength)
            for packet in BMAPPacket.parseAll(bytes) { accept(packet) }
        }
    }

    private func accept(_ packet: BMAPPacket) {
        guard var request = pending else { return }
        let direct = packet.functionBlock == request.expectedBlock && packet.function == request.expectedFunction
        let modeDump = request.drain && request.expectedBlock == 31 && request.expectedFunction == 1
            && packet.functionBlock == 31 && packet.function == 6
        guard direct || modeDump else { return }

        request.packets.append(packet)
        request.quietTask?.cancel()
        if !request.drain {
            pending = request
            finishPending(id: request.id, result: .success(request.packets))
            return
        }

        let id = request.id
        request.quietTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(550))
            guard let self, let current = self.pending, current.id == id else { return }
            self.finishPending(id: id, result: .success(current.packets))
        }
        pending = request
    }

    private func close() {
        if let channel, channel.isOpen() { channel.close() }
        channel = nil
        device = nil
        incoming.removeAll()
        failPending(BoseRFCOMMError.notConnected)
    }

    private func finishPending(id: UUID, result: Result<[BMAPPacket], Error>) {
        guard let request = pending, request.id == id else { return }
        pending = nil
        request.quietTask?.cancel()
        request.timeoutTask?.cancel()
        request.continuation.resume(with: result)
    }

    private func failPending(_ error: Error) {
        guard let request = pending else { return }
        finishPending(id: request.id, result: .failure(error))
    }
}
