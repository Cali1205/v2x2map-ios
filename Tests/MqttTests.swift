import XCTest
@testable import V2X2

final class MqttTests: XCTestCase {
    func testPublishEncoding() {
        let d = MqttPacket.publish("a/b", Data([1, 2]))
        XCTAssertEqual([UInt8](d), [0x30, 7, 0, 3, 0x61, 0x2F, 0x62, 1, 2])
    }

    func testRemainingLengthVarint() {
        let d = MqttPacket.packet(0x30, Data(count: 321))
        XCTAssertEqual([UInt8](d.prefix(3)), [0x30, 0xC1, 0x02])  // 321 = 65 + 2*128
        XCTAssertEqual(d.count, 324)
    }

    func testConnectFlags() {
        let anon = [UInt8](MqttPacket.connect(clientId: "c", user: "", password: "x", willTopic: "t", will: "w"))
        XCTAssertEqual(anon[9], 0x2E)  // clean + will QoS1 retained, no password without user
        let auth = [UInt8](MqttPacket.connect(clientId: "c", user: "u", password: "p", willTopic: "t", will: "w"))
        XCTAssertEqual(auth[9], 0xEE)
        XCTAssertEqual(auth.suffix(6), [0, 1, 0x75, 0, 1, 0x70])
    }

    func testBrokerURLs() {
        let c = MqttClient.Config(url: "cits1.opentrafficmap.org", user: "", password: "", node: "n")
        XCTAssertEqual(c?.tls, true); XCTAssertEqual(c?.port, 8883)
        let p = MqttClient.Config(url: " mqtt://192.168.1.5 ", user: "", password: "", node: "n")
        XCTAssertEqual(p?.tls, false); XCTAssertEqual(p?.port, 1883); XCTAssertEqual(p?.host, "192.168.1.5")
        XCTAssertNil(MqttClient.Config(url: "http://x", user: "", password: "", node: "n"))
        XCTAssertNil(MqttClient.Config(url: "", user: "", password: "", node: "n"))
    }
}
