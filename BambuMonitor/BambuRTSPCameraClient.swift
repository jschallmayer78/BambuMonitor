//
//  BambuRTSPCameraClient.swift
//  BambuMonitor
//
//  Kamera-Stream für X1-/H2-/P2-Modelle: RTSPS (RTSP über TLS) auf Port 322
//  mit Digest-Authentifizierung (LIVE555-Server), RTP interleaved über TCP,
//  H.264-Depacketierung (RFC 6184) und Hardware-Decoding per VideoToolbox.
//  P1-/A1-Modelle nutzen stattdessen das JPEG-Protokoll in BambuCameraClient.
//

import Foundation
import Network
import AppKit
import CryptoKit
import CoreMedia
import CoreImage
import VideoToolbox

@MainActor
final class BambuRTSPCameraClient {

    var onFrame: ((NSImage) -> Void)?
    var onError: ((String) -> Void)?
    /// Nur für Diagnose – meldet Handshake-Schritte und Streamzustand.
    var onDebug: ((String) -> Void)?

    private let host: String
    private let accessCode: String
    private var baseURI: String { "rtsps://\(host):322/streaming/live/1" }

    private var connection: NWConnection?
    private var buffer = Data()
    private var cseq = 0
    private var nonce: String?
    private var realm = "LIVE555 Streaming Media"
    private var sessionID: String?
    private var contentBase: String?
    private var keepaliveTimer: Timer?

    /// Ablauf des Handshakes: DESCRIBE (holt Auth-Nonce und SDP) → SETUP → PLAY.
    private enum Phase {
        case idle
        case describeNoAuth
        case describe
        case setup
        case play
        case streaming
    }
    private var phase: Phase = .idle

    private var depacketizer = H264Depacketizer()
    private var decoder = H264Decoder()
    private var pendingNALs: [Data] = []
    private var seenKeyframe = false

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
            to: .hostPort(host: NWEndpoint.Host(host), port: 322),
            using: NWParameters(tls: tlsOptions)
        )
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.onDebug?("Verbindungsstatus: \(state)")
                switch state {
                case .ready:
                    self.phase = .describeNoAuth
                    self.sendRequest(method: "DESCRIBE", uri: self.baseURI, extraHeaders: ["Accept: application/sdp"], authenticated: false)
                    self.receive()
                case .failed(let error):
                    self.stop()
                    self.onError?("RTSP nicht erreichbar: \(error.localizedDescription)")
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    func stop() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        phase = .idle
        cseq = 0
        nonce = nil
        sessionID = nil
        contentBase = nil
        pendingNALs.removeAll()
        seenKeyframe = false
        depacketizer = H264Depacketizer()
        decoder = H264Decoder()
    }

    // MARK: - RTSP-Requests

    private func sendRequest(method: String, uri: String, extraHeaders: [String] = [], authenticated: Bool = true) {
        cseq += 1
        var lines = [
            "\(method) \(uri) RTSP/1.0",
            "CSeq: \(cseq)",
            "User-Agent: BambuMonitor",
        ]
        if authenticated, let nonce {
            lines.append("Authorization: \(digestHeader(method: method, uri: uri, nonce: nonce))")
        }
        if let sessionID {
            lines.append("Session: \(sessionID)")
        }
        lines.append(contentsOf: extraHeaders)
        let request = lines.joined(separator: "\r\n") + "\r\n\r\n"
        connection?.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
    }

    private func digestHeader(method: String, uri: String, nonce: String) -> String {
        func md5(_ s: String) -> String {
            Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let ha1 = md5("bblp:\(realm):\(accessCode)")
        let ha2 = md5("\(method):\(uri)")
        let response = md5("\(ha1):\(nonce):\(ha2)")
        return "Digest username=\"bblp\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(uri)\", response=\"\(response)\""
    }

    private var trackURI: String {
        (contentBase ?? baseURI + "/") + "track1"
    }

    private var playURI: String {
        contentBase ?? baseURI
    }

    // MARK: - Empfang

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
        while !buffer.isEmpty {
            // Interleaved-Binärdaten beginnen mit '$', RTSP-Antworten mit Text.
            if buffer[buffer.startIndex] == 0x24 {
                guard buffer.count >= 4 else { return }
                let start = buffer.startIndex
                let channel = buffer[start + 1]
                let length = Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
                guard buffer.count >= 4 + length else { return }
                let packet = Data(buffer.subdata(in: (start + 4)..<(start + 4 + length)))
                buffer.removeFirst(4 + length)
                if channel == 0 { // Kanal 0 = RTP (Video), Kanal 1 = RTCP (ignoriert)
                    handleRTPPacket(packet)
                }
            } else {
                guard let response = parseResponse() else { return }
                handleResponse(response)
            }
        }
    }

    private struct RTSPResponse {
        var statusCode: Int
        var headers: [String: String] // Schlüssel kleingeschrieben
        var body: Data
    }

    /// Liest eine vollständige RTSP-Antwort aus dem Puffer, sonst nil.
    private func parseResponse() -> RTSPResponse? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            buffer.removeAll()
            return nil
        }
        var headers: [String: String] = [:]
        let lines = headerText.components(separatedBy: "\r\n")
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let totalLength = buffer.distance(from: buffer.startIndex, to: headerEnd.upperBound) + contentLength
        guard buffer.count >= totalLength else { return nil }

        let body = buffer.subdata(in: headerEnd.upperBound..<(buffer.startIndex + totalLength))
        buffer.removeFirst(totalLength)

        let statusParts = lines.first?.components(separatedBy: " ") ?? []
        let statusCode = statusParts.count >= 2 ? Int(statusParts[1]) ?? 0 : 0
        return RTSPResponse(statusCode: statusCode, headers: headers, body: body)
    }

    private func handleResponse(_ response: RTSPResponse) {
        onDebug?("Antwort: Status \(response.statusCode) in Phase \(phase)")
        // Auth-Challenge: Nonce übernehmen und den Request wiederholen.
        if response.statusCode == 401 {
            guard phase == .describeNoAuth, let authHeader = response.headers["www-authenticate"] else {
                fail("Anmeldung an der Kamera abgelehnt – Access Code prüfen")
                return
            }
            if let realmValue = Self.quotedValue(in: authHeader, key: "realm") {
                realm = realmValue
            }
            guard let nonceValue = Self.quotedValue(in: authHeader, key: "nonce") else {
                fail("Unerwartete Auth-Antwort der Kamera")
                return
            }
            nonce = nonceValue
            phase = .describe
            sendRequest(method: "DESCRIBE", uri: baseURI, extraHeaders: ["Accept: application/sdp"])
            return
        }

        guard response.statusCode == 200 else {
            if phase != .streaming {
                fail("Kamera-Fehler (RTSP-Status \(response.statusCode))")
            }
            return
        }

        switch phase {
        case .describeNoAuth, .describe:
            if let base = response.headers["content-base"] {
                contentBase = base
            }
            parseSDP(response.body)
            phase = .setup
            sendRequest(method: "SETUP", uri: trackURI, extraHeaders: ["Transport: RTP/AVP/TCP;unicast;interleaved=0-1"])
        case .setup:
            if let session = response.headers["session"] {
                sessionID = session.components(separatedBy: ";").first
            }
            phase = .play
            sendRequest(method: "PLAY", uri: playURI)
        case .play:
            phase = .streaming
            startKeepalive()
        case .streaming, .idle:
            break // Antwort auf Keepalive – ignorieren
        }
    }

    private func fail(_ message: String) {
        stop()
        onError?(message)
    }

    private static func quotedValue(in header: String, key: String) -> String? {
        guard let range = header.range(of: "\(key)=\"") else { return nil }
        let rest = header[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// Holt SPS/PPS aus dem SDP (sprop-parameter-sets), damit der Decoder
    /// schon vor dem ersten In-Band-Parametersatz konfiguriert werden kann.
    private func parseSDP(_ body: Data) {
        guard let sdp = String(data: body, encoding: .utf8) else { return }
        for line in sdp.components(separatedBy: "\n") {
            guard let range = line.range(of: "sprop-parameter-sets=") else { continue }
            let value = line[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: ";").first ?? ""
            let parts = value.components(separatedBy: ",")
            if parts.count >= 2,
               let sps = Data(base64Encoded: parts[0]),
               let pps = Data(base64Encoded: parts[1]) {
                decoder.setParameterSets(sps: sps, pps: pps)
            }
        }
    }

    private func startKeepalive() {
        keepaliveTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.phase == .streaming else { return }
                self.sendRequest(method: "OPTIONS", uri: self.baseURI)
            }
        }
        // .common, damit der Keepalive auch bei UI-Interaktion feuert.
        RunLoop.main.add(timer, forMode: .common)
        keepaliveTimer = timer
    }

    // MARK: - RTP / H.264

    private func handleRTPPacket(_ packet: Data) {
        guard packet.count >= 12 else { return }
        let byte0 = packet[0]
        guard byte0 >> 6 == 2 else { return } // RTP-Version 2
        let hasPadding = byte0 & 0x20 != 0
        let hasExtension = byte0 & 0x10 != 0
        let csrcCount = Int(byte0 & 0x0F)
        let marker = packet[1] & 0x80 != 0

        var offset = 12 + csrcCount * 4
        if hasExtension {
            guard packet.count >= offset + 4 else { return }
            let extensionWords = Int(packet[offset + 2]) << 8 | Int(packet[offset + 3])
            offset += 4 + extensionWords * 4
        }
        var end = packet.count
        if hasPadding, let padding = packet.last.map(Int.init), padding <= end - offset {
            end -= padding
        }
        guard offset < end else { return }

        let nalUnits = depacketizer.nalUnits(fromRTPPayload: packet.subdata(in: offset..<end))
        for nal in nalUnits {
            guard let first = nal.first else { continue }
            switch first & 0x1F {
            case 7, 8:
                decoder.addInbandParameterSet(nal)
            case 1, 5:
                if first & 0x1F == 5 { seenKeyframe = true }
                pendingNALs.append(nal)
            default:
                break
            }
        }

        // Marker-Bit = Ende des Access Units → Bild dekodieren.
        if marker && !pendingNALs.isEmpty {
            defer { pendingNALs.removeAll() }
            guard seenKeyframe else {
                onDebug?("Warte auf Keyframe (\(pendingNALs.count) NALs verworfen)")
                return
            }
            if let image = decoder.decode(nalUnits: pendingNALs) {
                onFrame?(image)
            } else {
                onDebug?("Dekodieren fehlgeschlagen (\(pendingNALs.count) NALs)")
            }
        }
    }
}

// MARK: - H.264-Depacketierung (RFC 6184, packetization-mode=1)

private struct H264Depacketizer {
    private var fragmentBuffer: Data?

    mutating func nalUnits(fromRTPPayload slice: Data) -> [Data] {
        let payload = Data(slice) // auf 0-basierte Indizes normalisieren
        guard let first = payload.first else { return [] }

        switch first & 0x1F {
        case 1...23: // einzelne NAL-Unit
            fragmentBuffer = nil
            return [payload]
        case 24: // STAP-A: mehrere NAL-Units mit 2-Byte-Längenpräfix
            fragmentBuffer = nil
            var result: [Data] = []
            var i = 1
            while i + 2 <= payload.count {
                let size = Int(payload[i]) << 8 | Int(payload[i + 1])
                i += 2
                guard size > 0, i + size <= payload.count else { break }
                result.append(payload.subdata(in: i..<(i + size)))
                i += size
            }
            return result
        case 28: // FU-A: fragmentierte NAL-Unit
            guard payload.count >= 2 else { return [] }
            let fuHeader = payload[1]
            let isStart = fuHeader & 0x80 != 0
            let isEnd = fuHeader & 0x40 != 0
            if isStart {
                var nal = Data([first & 0xE0 | fuHeader & 0x1F])
                nal.append(payload.dropFirst(2))
                fragmentBuffer = nal
            } else if fragmentBuffer != nil {
                fragmentBuffer?.append(payload.dropFirst(2))
            }
            if isEnd, let complete = fragmentBuffer {
                fragmentBuffer = nil
                return [complete]
            }
            return []
        default:
            return []
        }
    }
}

// MARK: - H.264-Decoder (VideoToolbox)

@MainActor
private final class H264Decoder {
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var sps: Data?
    private var pps: Data?
    private let ciContext = CIContext()

    func setParameterSets(sps: Data, pps: Data) {
        self.sps = sps
        self.pps = pps
    }

    func addInbandParameterSet(_ nal: Data) {
        guard let first = nal.first else { return }
        switch first & 0x1F {
        case 7: sps = nal
        case 8: pps = nal
        default: break
        }
    }

    /// Dekodiert ein Access Unit (VCL-NALs eines Bildes) und liefert das Bild.
    func decode(nalUnits: [Data]) -> NSImage? {
        guard ensureSession() else { return nil }
        guard let session, let formatDescription else { return nil }

        // NAL-Units ins AVCC-Format bringen (4-Byte-Längenpräfix).
        var avcc = Data()
        for nal in nalUnits {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: 0, blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        let copyResult = avcc.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: avcc.count
            )
        }
        guard copyResult == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSizes = [avcc.count]
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: formatDescription, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSizes,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        // Synchron dekodieren – der Handler läuft dadurch noch vor dem Return.
        final class ResultBox: @unchecked Sendable {
            var imageBuffer: CVImageBuffer?
        }
        let box = ResultBox()
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil) { _, _, imageBuffer, _, _ in
            box.imageBuffer = imageBuffer
        }

        guard let imageBuffer = box.imageBuffer else { return nil }
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: ciImage.extent.width, height: ciImage.extent.height))
    }

    private func ensureSession() -> Bool {
        if session != nil { return true }
        guard let sps, let pps else { return false }

        var formatDesc: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes -> OSStatus in
            pps.withUnsafeBytes { ppsBytes -> OSStatus in
                let pointers: [UnsafePointer<UInt8>] = [
                    spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &formatDesc
                )
            }
        }
        guard status == noErr, let formatDesc else { return false }
        formatDescription = formatDesc

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        ]
        var newSession: VTDecompressionSession?
        guard VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: formatDesc,
            decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &newSession
        ) == noErr else { return false }
        session = newSession
        return true
    }
}
