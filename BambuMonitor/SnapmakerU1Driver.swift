//
//  SnapmakerU1Driver.swift
//  BambuMonitor
//
//  Anbindung des Snapmaker U1: Der Drucker ist Klipper-basiert und stellt
//  die Standard-Moonraker-HTTP-API auf Port 80 bereit (ohne API-Key).
//  Der Treiber pollt alle 3 Sekunden die relevanten Drucker-Objekte:
//  print_stats, display_status, Extruder-/Bett-Temperaturen, den
//  Bauraum-Sensor sowie die vier Filament-Slots (AFC_lane E0–E3).
//

import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor
final class SnapmakerU1Driver: PrinterDriver {
    var onSnapshot: ((PrinterSnapshot) -> Void)?
    var onStatus: ((ConnectionStatus) -> Void)?

    private let host: String
    private var pollTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var isConnected = false

    private static let queryObjects = [
        "print_stats", "display_status", "heater_bed",
        "extruder", "extruder1", "extruder2", "extruder3",
        "toolhead", "temperature_sensor cavity",
        "AFC_lane E0", "AFC_lane E1", "AFC_lane E2", "AFC_lane E3",
    ]

    init(host: String) {
        self.host = host
    }

    func connect() {
        disconnect()
        onStatus?(.connecting)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func disconnect() {
        pollTask?.cancel()
        pollTask = nil
        isConnected = false
        consecutiveFailures = 0
    }

    func refresh() {
        Task { [weak self] in
            await self?.poll()
        }
    }

    private var queryURL: URL? {
        let query = Self.queryObjects
            .joined(separator: "&")
            .addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: " ").inverted)
        return URL(string: "http://\(host)/printer/objects/query?\(query ?? "")")
    }

    private func poll() async {
        guard let url = queryURL else {
            onStatus?(.disconnected("Ungültige Adresse"))
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let status = result["status"] as? [String: Any] else {
                throw URLError(.cannotParseResponse)
            }
            consecutiveFailures = 0
            if !isConnected {
                isConnected = true
                onStatus?(.connected)
            }
            onSnapshot?(Self.parseSnapshot(from: status))
        } catch {
            consecutiveFailures += 1
            // Einen einzelnen Aussetzer tolerieren, erst danach als
            // getrennt melden – der Poll-Loop versucht es ohnehin weiter.
            if consecutiveFailures == 2 {
                isConnected = false
                onStatus?(.disconnected("Drucker nicht erreichbar"))
            }
        }
    }

    // MARK: - Parsing

    private static func parseSnapshot(from status: [String: Any]) -> PrinterSnapshot {
        var s = PrinterSnapshot()

        let printStats = status["print_stats"] as? [String: Any] ?? [:]
        switch printStats["state"] as? String ?? "" {
        case "printing": s.activity = .printing
        case "paused": s.activity = .paused
        case "complete": s.activity = .finished
        case "error": s.activity = .failed
        case "standby", "cancelled": s.activity = .idle
        default: s.activity = .unknown
        }

        s.taskName = (printStats["filename"] as? String ?? "")
            .replacingOccurrences(of: ".gcode", with: "")
        if let info = printStats["info"] as? [String: Any] {
            s.currentLayer = int(info["current_layer"]) ?? 0
            s.totalLayers = int(info["total_layer"]) ?? 0
        }

        let progress = double((status["display_status"] as? [String: Any])?["progress"]) ?? 0
        s.progressPercent = Int((progress * 100).rounded())

        // Moonraker liefert keine Restzeit – aus Fortschritt und bisheriger
        // Druckdauer hochrechnen.
        if s.activity == .printing || s.activity == .paused,
           progress > 0.005,
           let duration = double(printStats["print_duration"]), duration > 0 {
            s.remainingMinutes = Int((duration * (1 - progress) / progress / 60).rounded())
        }

        // Temperaturen des aktiven Werkzeugs
        let activeExtruder = (status["toolhead"] as? [String: Any])?["extruder"] as? String ?? "extruder"
        let activeIndex = Int(activeExtruder.dropFirst("extruder".count)) ?? 0
        if let extruder = status[activeExtruder] as? [String: Any] {
            s.nozzleTemp = double(extruder["temperature"]) ?? 0
            s.nozzleTarget = double(extruder["target"]) ?? 0
        }
        if let bed = status["heater_bed"] as? [String: Any] {
            s.bedTemp = double(bed["temperature"]) ?? 0
            s.bedTarget = double(bed["target"]) ?? 0
        }
        if let cavity = status["temperature_sensor cavity"] as? [String: Any] {
            s.chamberTemp = double(cavity["temperature"])
        }

        // Die vier Filament-Slots (AFC-Lanes)
        var trays: [FilamentTray] = []
        for i in 0..<4 {
            guard let lane = status["AFC_lane E\(i)"] as? [String: Any] else { continue }
            let loaded = lane["load"] as? Bool ?? false
            let material = lane["material"] as? String ?? ""
            let colorHex = (lane["color"] as? String ?? "#808080")
                .replacingOccurrences(of: "#", with: "")
            trays.append(FilamentTray(
                id: "S\(i + 1)",
                material: loaded ? (material.isEmpty ? "Unbekannt" : material) : "Leer",
                colorHex: colorHex,
                remainPercent: nil
            ))
        }
        if !trays.isEmpty {
            s.amsUnits = [AMSUnit(
                id: "0",
                humidityText: nil,
                temperature: nil,
                trays: trays,
                customName: "Filament-Slots"
            )]
            s.activeTrayID = "S\(activeIndex + 1)"
        }
        return s
    }

    private static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

// MARK: - Snapshot-Kamera

/// Kamerabild für Moonraker-Drucker: pollt die Snapshot-URL der Webcam
/// (~1 Bild/Sekunde). Der WebRTC-Livestream des U1 wäre deutlich
/// aufwändiger; für die Popover-Vorschau reicht das Snapshot-Polling.
@MainActor
final class HTTPSnapshotCameraClient {
    var onFrame: ((PlatformImage) -> Void)?
    var onError: ((String) -> Void)?

    private let snapshotURL: URL?
    private var pollTask: Task<Void, Never>?
    private var consecutiveFailures = 0

    init(host: String) {
        snapshotURL = URL(string: "http://\(host)/webcam/snapshot.jpg")
    }

    func start() {
        stop()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchFrame()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        consecutiveFailures = 0
    }

    private func fetchFrame() async {
        guard let snapshotURL else {
            onError?("Ungültige Kamera-Adresse")
            return
        }
        var request = URLRequest(url: snapshotURL)
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let image = PlatformImage(data: data) else { throw URLError(.cannotDecodeContentData) }
            consecutiveFailures = 0
            onFrame?(image)
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures == 3 {
                onError?("Kamera nicht erreichbar")
            }
        }
    }
}
