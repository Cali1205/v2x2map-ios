import Foundation
import Network
import Observation
import Security

/// Minimal MQTT 3.1.1 publisher (QoS 0), the iOS counterpart of the Android MqttBridge:
/// raw 802.11 frames go to `its/<node>/packet`, `online`/`offline` (retained) to `its/<node>/status`.
@Observable
final class MqttClient {
    enum State: Equatable { case off, connecting, connected, failed(String) }

    struct Config: Equatable {
        var host: String, port: UInt16, tls: Bool, user: String, password: String, node: String

        /// Accepts `mqtts://host:port`, `mqtt://host:port` (also `ssl://`/`tcp://`) or a bare host (TLS, 8883).
        init?(url: String, user: String, password: String, node: String) {
            let raw = url.trimmingCharacters(in: .whitespaces)
            guard let c = URLComponents(string: raw.contains("://") ? raw : "mqtts://" + raw),
                  let host = c.host, !host.isEmpty,
                  let scheme = c.scheme?.lowercased(), ["mqtt", "mqtts", "tcp", "ssl"].contains(scheme) else { return nil }
            tls = scheme == "mqtts" || scheme == "ssl"
            guard let port = UInt16(exactly: c.port ?? (tls ? 8883 : 1883)), port > 0 else { return nil }
            self.host = host; self.port = port; self.user = user; self.password = password; self.node = node
        }
    }

    private(set) var state: State = .off
    private(set) var sent = 0

    @ObservationIgnored private var config: Config?
    @ObservationIgnored private var conn: NWConnection?
    @ObservationIgnored private var ping: Timer?
    @ObservationIgnored private var retry: DispatchWorkItem?

    /// Idempotent: reconnects only if the configuration changed.
    func start(_ cfg: Config) {
        guard cfg != config else { return }
        stop()
        config = cfg
        connect()
    }

    func stop() {
        retry?.cancel(); ping?.invalidate()
        if let c = conn, state == .connected, let cfg = config {
            c.send(content: MqttPacket.publish("its/\(cfg.node)/status", Data("offline".utf8), retain: true), completion: .idempotent)
            c.send(content: MqttPacket.disconnect, completion: .contentProcessed { _ in c.cancel() })
        } else {
            conn?.cancel()
        }
        conn = nil; config = nil; state = .off
    }

    func publish(_ payload: Data) {
        guard state == .connected, let c = conn, let cfg = config else { return }
        c.send(content: MqttPacket.publish("its/\(cfg.node)/packet", payload), completion: .idempotent)
        sent += 1
    }

    private func connect() {
        guard let cfg = config, let port = NWEndpoint.Port(rawValue: cfg.port) else { return }
        let c = NWConnection(host: .init(cfg.host), port: port, using: cfg.tls ? .tls : .tcp)
        conn = c
        state = .connecting
        c.stateUpdateHandler = { [weak self, weak c] st in
            guard let self, let c, c === self.conn else { return }
            switch st {
            case .ready:
                c.send(content: MqttPacket.connect(clientId: "ios-bridge-\(cfg.node)", user: cfg.user, password: cfg.password,
                                                   willTopic: "its/\(cfg.node)/status", will: "offline"),
                       completion: .idempotent)
                awaitConnack(c, cfg)
            case .waiting(let e): state = .failed(e.localizedDescription)  // NWConnection retries by itself
            case .failed(let e): fail(e.localizedDescription)
            default: break
            }
        }
        c.start(queue: .main)
    }

    private func awaitConnack(_ c: NWConnection, _ cfg: Config) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, err in
            guard let self, c === conn else { return }
            guard let d = data, d.count == 4, d[d.startIndex] == 0x20 else { return fail(err?.localizedDescription ?? "Keine Antwort vom Broker") }
            let code = d[d.startIndex + 3]
            guard code == 0 else {
                // Wrong credentials etc. would fail again on retry.
                state = .failed(code == 4 || code == 5 ? "Zugangsdaten abgelehnt" : "Broker lehnt ab (Code \(code))")
                c.cancel(); conn = nil
                return
            }
            state = .connected
            c.send(content: MqttPacket.publish("its/\(cfg.node)/status", Data("online".utf8), retain: true), completion: .idempotent)
            ping = Timer.scheduledTimer(withTimeInterval: Double(MqttPacket.keepAlive) * 0.8, repeats: true) { [weak c] _ in
                c?.send(content: MqttPacket.pingreq, completion: .idempotent)
            }
            drain(c)
        }
    }

    /// Discards PINGRESPs; notices when the broker closes the connection.
    private func drain(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, done, err in
            guard let self, c === conn else { return }
            if done || err != nil { fail(err?.localizedDescription ?? "Verbindung getrennt") } else { drain(c) }
        }
    }

    private func fail(_ msg: String) {
        ping?.invalidate()
        conn?.cancel(); conn = nil
        state = .failed(msg)
        let w = DispatchWorkItem { [weak self] in if self?.conn == nil, self?.config != nil { self?.connect() } }
        retry = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: w)
    }
}

enum MqttPacket {
    static let keepAlive: UInt16 = 60
    static let pingreq = Data([0xC0, 0x00])
    static let disconnect = Data([0xE0, 0x00])

    static func connect(clientId: String, user: String, password: String, willTopic: String, will: String) -> Data {
        var flags: UInt8 = 0x02 | 0x04 | 0x08 | 0x20  // clean session, will, will QoS 1, will retain
        if !user.isEmpty {
            flags |= 0x80
            if !password.isEmpty { flags |= 0x40 }  // MQTT 3.1.1 forbids a password without user name
        }
        var body = str("MQTT") + Data([4, flags, UInt8(keepAlive >> 8), UInt8(keepAlive & 0xFF)])
        body += str(clientId) + str(willTopic) + str(will)
        if flags & 0x80 != 0 { body += str(user) }
        if flags & 0x40 != 0 { body += str(password) }
        return packet(0x10, body)
    }

    static func publish(_ topic: String, _ payload: Data, retain: Bool = false) -> Data {
        packet(retain ? 0x31 : 0x30, str(topic) + payload)
    }

    static func packet(_ header: UInt8, _ body: Data) -> Data {
        var d = Data([header])
        var n = body.count
        repeat {
            var b = UInt8(n % 128)
            n /= 128
            if n > 0 { b |= 0x80 }
            d.append(b)
        } while n > 0
        return d + body
    }

    private static func str(_ s: String) -> Data {
        let u = Data(s.utf8)
        return Data([UInt8(u.count >> 8), UInt8(u.count & 0xFF)]) + u
    }
}

/// The broker password lives in the Keychain, not in UserDefaults (which ends up in unencrypted backups).
enum MqttPassword {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                               kSecAttrService as String: "mqtt-broker"]

    static func get() -> String {
        var q = query
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    static func set(_ value: String) {
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}
