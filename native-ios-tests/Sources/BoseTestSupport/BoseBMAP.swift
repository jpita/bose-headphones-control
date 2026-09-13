import Foundation

public enum BMAPOperator: UInt8 { case set = 0, get = 1, setGet = 2, status = 3, error = 4, start = 5, result = 6 }

public struct BMAPPacket: Equatable {
    public let functionBlock: UInt8
    public let function: UInt8
    public let operation: UInt8
    public let payload: Data

    public init(_ block: UInt8, _ function: UInt8, _ operation: BMAPOperator, payload: Data = Data()) {
        functionBlock = block; self.function = function; self.operation = operation.rawValue; self.payload = payload
    }

    public var data: Data { Data([functionBlock, function, operation, UInt8(payload.count)]) + payload }
}

public func segmentBMAP(_ data: Data, payloadSize: Int = 19) -> [Data] {
    guard !data.isEmpty else { return [Data([0])] }
    let count = (data.count + payloadSize - 1) / payloadSize
    return (0..<count).map { index in
        let start = index * payloadSize
        let end = min(start + payloadSize, data.count)
        return Data([(UInt8(count - 1) << 4) | UInt8(index)]) + data[start..<end]
    }
}

public final class MockBluetoothConnection {
    public private(set) var isConnected = false
    public private(set) var requests: [BMAPPacket] = []
    public var currentMode: UInt8 = 0

    public init() {}
    public func connect() { isConnected = true }
    public func disconnect() { isConnected = false }

    public func exchange(_ request: BMAPPacket) throws -> BMAPPacket {
        guard isConnected else { throw NSError(domain: "MockBluetooth", code: 1) }
        requests.append(request)
        if request.functionBlock == 31 && request.function == 3 && request.operation == BMAPOperator.start.rawValue {
            currentMode = request.payload[request.payload.startIndex]
            return BMAPPacket(31, 3, .result, payload: Data([currentMode]))
        }
        if request.functionBlock == 31 && request.function == 3 {
            return BMAPPacket(31, 3, .status, payload: Data([currentMode]))
        }
        return BMAPPacket(request.functionBlock, request.function, .status, payload: request.payload)
    }
}
