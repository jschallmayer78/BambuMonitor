//
//  BambuMQTTClient.swift
//  BambuMonitor
//
//  Minimaler MQTT-3.1.1-Client für den lokalen Zugriff auf Bambu Lab Drucker.
//  Der Drucker stellt einen MQTT-Broker über TLS auf Port 8883 bereit
//  (Benutzer "bblp", Passwort = LAN-Access-Code, selbstsigniertes Zertifikat).
//  Implementiert nur, was dafür nötig ist: CONNECT, SUBSCRIBE, PUBLISH (QoS 0/1),
//  PUBACK und PINGREQ – ohne externe Abhängigkeiten, direkt auf Network.framework.
//

import Foundation
import Network

@MainActor
final class BambuMQTTClient {

    enum State {
        case connecting
        case connected
        case disconnected(reason: String?)
    }

    var onStateChange: ((State) -> Void)?
    var onMessage: ((_ topic: String, _ payload: Data) -> Void)?

    private let host: String
    private let accessCode: String
    private let serial: String

    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var pingTimer: Timer?
    private var nextPacketID: UInt16 = 1

    private var reportTopic: String { "device/\(serial)/report" }
    private var requestTopic: String { "device/\(serial)/request" }

    init(host: String, accessCode: String, serial: String) {
        self.host = host
        self.accessCode = accessCode
        self.serial = serial
    }

    // MARK: - Verbindungsaufbau

    func connect() {
        disconnect(reason: nil, notify: false)
        onStateChange?(.connecting)

        // Bambu-Drucker verwenden ein selbstsigniertes Zertifikat – die
        // Zertifikatsprüfung muss daher deaktiviert werden.
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, .main)

        let parameters = NWParameters(tls: tlsOptions)
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: 8883)
        )
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(state)
            }
        }
        connection.start(queue: .main)
    }

    func disconnect(reason: String? = nil, notify: Bool = true) {
        pingTimer?.invalidate()
        pingTimer = nil
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()
        if notify {
            onStateChange?(.disconnected(reason: reason))
        }
    }

    /// Fordert einen vollständigen Statusbericht an ("pushall").
    func requestFullStatus() {
        let payload = #"{"pushing":{"sequence_id":"1","command":"pushall"},"user_id":"bambumonitor"}"#
        publish(topic: requestTopic, payload: Data(payload.utf8))
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            sendConnectPacket()
            startReceiving()
        case .failed(let error):
            disconnect(reason: error.localizedDescription)
        case .cancelled:
            break
        default:
            break
        }
    }

    // MARK: - Senden

    private func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func sendConnectPacket() {
        var variableHeader = Data()
        variableHeader.appendMQTTString("MQTT")
        variableHeader.append(4) // Protokollversion 3.1.1
        variableHeader.append(0b1100_0010) // Username + Passwort + Clean Session
        variableHeader.appendUInt16(60) // Keepalive in Sekunden

        var payload = Data()
        // Pro Verbindung eine eindeutige Client-ID: Der Broker beendet
        // Sessions mit gleicher ID – ein hängender alter Socket würde sonst
        // mit der neuen Verbindung um die Session kämpfen.
        payload.appendMQTTString("bambumonitor-\(UUID().uuidString.prefix(8))")
        payload.appendMQTTString("bblp")
        payload.appendMQTTString(accessCode)

        send(Self.packet(type: 0x10, body: variableHeader + payload))
    }

    private func sendSubscribe(topic: String) {
        var body = Data()
        body.appendUInt16(takePacketID())
        body.appendMQTTString(topic)
        body.append(0) // QoS 0
        send(Self.packet(type: 0x82, body: body))
    }

    private func publish(topic: String, payload: Data) {
        var body = Data()
        body.appendMQTTString(topic)
        body.append(payload)
        send(Self.packet(type: 0x30, body: body)) // QoS 0
    }

    private func sendPubAck(packetID: UInt16) {
        var body = Data()
        body.appendUInt16(packetID)
        send(Self.packet(type: 0x40, body: body))
    }

    private func sendPing() {
        send(Data([0xC0, 0x00]))
    }

    private func takePacketID() -> UInt16 {
        defer { nextPacketID = nextPacketID == .max ? 1 : nextPacketID + 1 }
        return nextPacketID
    }

    /// Baut ein MQTT-Paket aus Typ-Byte und Restinhalt (inkl. Längenkodierung).
    private static func packet(type: UInt8, body: Data) -> Data {
        var data = Data([type])
        var length = body.count
        repeat {
            var byte = UInt8(length % 128)
            length /= 128
            if length > 0 { byte |= 0x80 }
            data.append(byte)
        } while length > 0
        data.append(body)
        return data
    }

    // MARK: - Empfangen

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let content {
                    self.receiveBuffer.append(content)
                    self.processBuffer()
                }
                if let error {
                    self.disconnect(reason: error.localizedDescription)
                } else if isComplete {
                    self.disconnect(reason: "Verbindung vom Drucker beendet")
                } else {
                    self.startReceiving()
                }
            }
        }
    }

    /// Zerlegt den Empfangspuffer in vollständige MQTT-Pakete.
    private func processBuffer() {
        while true {
            guard receiveBuffer.count >= 2 else { return }

            // Variable Längenkodierung des Restpakets dekodieren.
            var remainingLength = 0
            var multiplier = 1
            var index = 1
            var lengthComplete = false
            while index < min(receiveBuffer.count, 5) {
                let byte = receiveBuffer[receiveBuffer.startIndex + index]
                remainingLength += Int(byte & 0x7F) * multiplier
                multiplier *= 128
                index += 1
                if byte & 0x80 == 0 {
                    lengthComplete = true
                    break
                }
            }
            guard lengthComplete else { return } // Längenfeld noch unvollständig

            let totalLength = index + remainingLength
            guard receiveBuffer.count >= totalLength else { return } // Paket unvollständig

            let packet = receiveBuffer.subdata(in: receiveBuffer.startIndex..<(receiveBuffer.startIndex + totalLength))
            receiveBuffer.removeFirst(totalLength)
            handlePacket(packet, headerLength: index)
        }
    }

    private func handlePacket(_ packet: Data, headerLength: Int) {
        let typeByte = packet[packet.startIndex]
        let body = packet.dropFirst(headerLength)

        switch typeByte & 0xF0 {
        case 0x20: // CONNACK
            let returnCode = body.count >= 2 ? body[body.startIndex + 1] : 0xFF
            if returnCode == 0 {
                onStateChange?(.connected)
                sendSubscribe(topic: reportTopic)
                requestFullStatus()
                startPingTimer()
            } else {
                disconnect(reason: "Anmeldung abgelehnt (Code \(returnCode)) – Access Code prüfen")
            }
        case 0x30: // PUBLISH
            handlePublish(typeByte: typeByte, body: Data(body))
        case 0x90, 0xD0: // SUBACK, PINGRESP
            break
        default:
            break
        }
    }

    private func handlePublish(typeByte: UInt8, body: Data) {
        var offset = body.startIndex
        guard body.count >= 2 else { return }
        let topicLength = Int(body[offset]) << 8 | Int(body[offset + 1])
        offset += 2
        guard body.distance(from: offset, to: body.endIndex) >= topicLength else { return }
        let topic = String(data: body.subdata(in: offset..<(offset + topicLength)), encoding: .utf8) ?? ""
        offset += topicLength

        let qos = (typeByte >> 1) & 0x03
        if qos > 0 {
            guard body.distance(from: offset, to: body.endIndex) >= 2 else { return }
            let packetID = UInt16(body[offset]) << 8 | UInt16(body[offset + 1])
            offset += 2
            sendPubAck(packetID: packetID)
        }

        let payload = body.subdata(in: offset..<body.endIndex)
        onMessage?(topic, payload)
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        let timer = Timer(timeInterval: 25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sendPing()
            }
        }
        // .common statt .default, damit der Ping auch während UI-Interaktion
        // (offenes Popover, Scrollen) feuert – sonst trennt der Broker
        // die Verbindung wegen ausbleibender Keepalives.
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }
}

private extension Data {
    /// Hängt einen UTF-8-String mit vorangestellter 2-Byte-Länge an (MQTT-Format).
    mutating func appendMQTTString(_ string: String) {
        let utf8 = Data(string.utf8)
        appendUInt16(UInt16(utf8.count))
        append(utf8)
    }

    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }
}
