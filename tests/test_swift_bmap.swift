import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct SwiftBMAPTests {
    static func main() throws {
        let packet = BMAPPacket(2, 2, .get)
        expect(packet.data == Data([2, 2, 1, 0]), "packet encoding")
        expect(BMAPPacket.parseAll(packet.data) == [packet], "packet parsing")

        let long = Data(0..<45)
        let segments = segmentBMAP(long)
        expect(segments.count == 3, "segmentation count")
        expect(segments.map(\.first) == [0x20, 0x21, 0x22], "segment headers")
        var reassembler = BMAPReassembler()
        var joined: Data?
        for segment in segments { joined = try reassembler.feed(segment) ?? joined }
        expect(joined == long, "segment reassembly")

        var status47 = Data(repeating: 0, count: 47)
        status47[0] = 2
        status47[3] = 1
        status47[4] = 1
        status47.replaceSubrange(6..<12, with: Data("Travel".utf8))
        status47[42] = 7
        status47[46] = 1
        guard let mode47 = BMAPModeConfig.parse(status47) else { throw BMAPError.malformedPacket }
        expect(mode47.name == "Travel", "47-byte mode name")
        expect(mode47.cncLevel == 7 && mode47.windBlock, "47-byte settings")
        let write47 = try mode47.writePayload()
        expect(write47.count == 39, "47-byte write layout")

        var status48 = Data(repeating: 0, count: 48)
        status48[0] = 4
        status48[3] = 1
        status48[4] = 1
        status48.replaceSubrange(6..<10, with: Data("Work".utf8))
        status48[42] = 3
        status48[47] = 1
        guard let mode48 = BMAPModeConfig.parse(status48) else { throw BMAPError.malformedPacket }
        expect(mode48.name == "Work", "48-byte mode name")
        expect(mode48.ancToggle, "48-byte ANC")
        let write48 = try mode48.writePayload()
        expect(write48.count == 40, "48-byte write layout")

        print("Swift BMAP tests passed")
    }
}
