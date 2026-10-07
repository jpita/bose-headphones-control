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

        expect(defaultModeName(index: 2, editable: true) == "", "empty editable slot has no default name")
        expect(defaultModeName(index: 3, editable: true) == "", "empty editable slot 3 has no default name")
        expect(defaultModeName(index: 0, editable: false) == "Quiet", "preset 0 name")
        expect(defaultModeName(index: 1, editable: false) == "Aware", "preset 1 name")
        expect(defaultModeName(index: 9, editable: false) == "Mode 9", "unknown preset name")

        expect(bmapActionNames[16] == "SpotifyGo", "action 16 name")
        expect(bmapEventNames[9] == "long_press", "event 9 name")
        expect(bmapButtonNames[128] == "Shortcut", "button 128 name")

        expect(autoOffMinutes(from: Data([0x05])) == 5, "auto-off 5 minutes read")
        expect(autoOffMinutes(from: Data([0x14])) == 20, "auto-off 20 minutes read")
        expect(autoOffMinutes(from: Data()) == nil, "auto-off empty payload")
        let autoOff20 = try autoOffPayload(minutes: 20)
        let autoOffNever = try autoOffPayload(minutes: 0)
        expect(autoOff20 == Data([0x14]), "auto-off 20 minutes write")
        expect(autoOffNever == Data([0]), "auto-off never write")
        expect((try? autoOffPayload(minutes: 256)) == nil, "auto-off above 255 rejected")
        expect((try? autoOffPayload(minutes: -1)) == nil, "auto-off below 0 rejected")
        expect(autoOffLabel(0) == "never" && autoOffLabel(40) == "40 min", "auto-off labels")

        print("Swift BMAP tests passed")
    }
}
