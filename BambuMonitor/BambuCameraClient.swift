//
//  BambuCameraClient.swift
//  BambuMonitor
//
//  Empfängt das Kamerabild des Druckers über das lokale Bambu-Kameraprotokoll:
//  TLS auf Port 6000, Authentifizierung mit "bblp" + Access Code, danach
//  sendet der Drucker fortlaufend JPEG-Frames mit 16-Byte-Header (Payload-
//  Größe als UInt32 little-endian). Unterstützt von P1-, A1- und X1-Serie
//  (bei X1 muss "LAN-Liveview" am Drucker aktiviert sein).
//

import Foundation
import Network
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor
final class BambuCameraClient {

    var onFrame: ((PlatformImage) -> Void)?
    var onError: ((String) -> Void)?

    private let host: String
    private let accessCode: String

    private var connection: NWConnection?
    private var buffer = Data()
    private var expectedPayloadSize: Int?

    init(host: String, accessCode: String) {
        self.host = host
        self.accessCode = accessCode
    }

    func start() {
        stop()

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, .main)

        let connection = NWConnection(
            to: .hostPort(host: NWEndpoint.Host(host), port: 6000),
            using: NWParameters(tls: tlsOptions)
        )
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.sendAuthPacket()
                    self.receive()
                case .failed(let error):
                    self.stop()
                    self.onError?("Kamera nicht erreichbar: \(error.localizedDescription)")
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    func stop() {
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        expectedPayloadSize = nil
    }

    private func sendAuthPacket() {
        var packet = Data()
        packet.appendUInt32LE(0x40)
        packet.appendUInt32LE(0x3000)
        packet.appendUInt32LE(0)
        packet.appendUInt32LE(0)
        packet.append(Self.padded("bblp", length: 32))
        packet.append(Self.padded(accessCode, length: 32))
        connection?.send(content: packet, completion: .contentProcessed { _ in })
    }

    private static func padded(_ string: String, length: Int) -> Data {
        var data = Data(string.utf8.prefix(length))
        data.append(Data(count: length - data.count))
        return data
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 262144) { [weak self] content, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let content {
                    self.buffer.append(content)
                    self.processBuffer()
                }
                if error != nil || isComplete {
                    self.stop()
                    self.onError?("Kamera-Verbindung beendet")
                } else {
                    self.receive()
                }
            }
        }
    }

    private func processBuffer() {
        while true {
            if let expected = expectedPayloadSize {
                guard buffer.count >= expected else { return }
                let frameData = buffer.subdata(in: buffer.startIndex..<(buffer.startIndex + expected))
                buffer.removeFirst(expected)
                expectedPayloadSize = nil
                if let image = PlatformImage(data: frameData) {
                    onFrame?(image)
                }
            } else {
                guard buffer.count >= 16 else { return }
                let start = buffer.startIndex
                let size = Int(buffer[start])
                    | Int(buffer[start + 1]) << 8
                    | Int(buffer[start + 2]) << 16
                    | Int(buffer[start + 3]) << 24
                buffer.removeFirst(16)
                // Plausibilitätsprüfung – schützt vor Desynchronisation im Stream.
                guard size > 0, size < 5_000_000 else {
                    stop()
                    onError?("Ungültige Kameradaten empfangen")
                    return
                }
                expectedPayloadSize = size
            }
        }
    }
}

private extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
