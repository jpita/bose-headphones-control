import XCTest
@testable import BoseTestSupport

final class MockBluetoothTests: XCTestCase {
    func testMockConnectionRejectsRequestsBeforeConnect() {
        let mock = MockBluetoothConnection()
        XCTAssertThrowsError(try mock.exchange(BMAPPacket(31, 3, .get)))
        XCTAssertFalse(mock.isConnected)
    }

    func testModeCommandIsAppliedAndReadBackFromMock() throws {
        let mock = MockBluetoothConnection()
        mock.connect()
        _ = try mock.exchange(BMAPPacket(31, 3, .start, payload: Data([1, 1])))
        let status = try mock.exchange(BMAPPacket(31, 3, .get))
        XCTAssertEqual(status.payload, Data([1]))
        XCTAssertEqual(mock.requests.map(\.operation), [BMAPOperator.start.rawValue, BMAPOperator.get.rawValue])
    }

    func testBLESegmentationMatchesHeadphonePacketBoundaries() {
        let packet = BMAPPacket(31, 6, .setGet, payload: Data(0..<45))
        let segments = segmentBMAP(packet.data)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.map { $0.first }, [0x20, 0x21, 0x22])
        XCTAssertEqual(segments.reduce(0) { $0 + $1.count }, packet.data.count + segments.count)
    }
}
