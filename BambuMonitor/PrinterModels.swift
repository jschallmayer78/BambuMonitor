//
//  PrinterModels.swift
//  BambuMonitor
//
//  Datenmodelle für den Zustand eines Bambu Lab Druckers.
//

import SwiftUI

/// Aktivitätszustand des Druckers, abgeleitet aus `gcode_state` im MQTT-Report.
enum PrinterActivity: String {
    case idle = "IDLE"
    case printing = "RUNNING"
    case paused = "PAUSE"
    case finished = "FINISH"
    case failed = "FAILED"
    case preparing = "PREPARE"
    case slicing = "SLICING"
    case unknown = "UNKNOWN"

    var displayName: String {
        switch self {
        case .idle: return "Bereit"
        case .printing: return "Druckt"
        case .paused: return "Pausiert"
        case .finished: return "Fertig"
        case .failed: return "Fehlgeschlagen"
        case .preparing: return "Vorbereitung"
        case .slicing: return "Slicing"
        case .unknown: return "Unbekannt"
        }
    }

    var subtitle: String {
        switch self {
        case .printing: return "Druck läuft"
        case .paused: return "Druck pausiert"
        case .finished: return "Druck abgeschlossen"
        case .failed: return "Druck fehlgeschlagen"
        case .preparing: return "Druck wird vorbereitet"
        case .slicing: return "Modell wird gesliced"
        case .idle: return "Kein aktiver Druck"
        case .unknown: return "Status unbekannt"
        }
    }

    var color: Color {
        switch self {
        case .printing: return .blue
        case .paused: return .orange
        case .finished: return .green
        case .failed: return .red
        case .preparing, .slicing: return .cyan
        case .idle, .unknown: return .gray
        }
    }
}

/// Ein Filament-Slot – entweder im AMS oder die externe Spule.
struct FilamentTray: Identifiable {
    var id: String          // z. B. "A1" oder "EXT"
    var material: String    // z. B. "PLA Basic"
    var colorHex: String    // RGBA-Hex, z. B. "FFAA00FF"
    var remainPercent: Int? // -1/nil wenn unbekannt

    var color: Color {
        Color(rgbaHex: colorHex) ?? .gray
    }
}

/// Eine Filament-Einheit mit mehreren Slots – bei Bambu ein AMS-Modul,
/// beim Snapmaker U1 die vier AFC-Lanes.
struct AMSUnit: Identifiable {
    var id: String              // "0" → Anzeige "AMS A"
    var humidityText: String?   // z. B. "26%" oder Stufe "2/5"
    var temperature: Double?
    var trays: [FilamentTray]
    /// Überschreibt den generierten "AMS A"-Namen (z. B. "Filament-Slots").
    var customName: String?

    var displayName: String {
        if let customName { return customName }
        let index = Int(id) ?? 0
        let letter = Character(UnicodeScalar(65 + min(index, 25))!)
        return "AMS \(letter)"
    }
}

/// Zusammengefasster Druckerzustand für die UI.
struct PrinterSnapshot {
    var taskName: String = ""
    var activity: PrinterActivity = .unknown
    var progressPercent: Int = 0
    var remainingMinutes: Int = 0
    var currentLayer: Int = 0
    var totalLayers: Int = 0
    var nozzleTemp: Double = 0
    var nozzleTarget: Double = 0
    var bedTemp: Double = 0
    var bedTarget: Double = 0
    var chamberTemp: Double?
    var amsUnits: [AMSUnit] = []
    var externalSpool: FilamentTray?
    /// ID des aktiven Slots (entspricht FilamentTray.id, z. B. "A1", "EXT", "S2").
    var activeTrayID: String?

    var remainingText: String {
        guard remainingMinutes > 0 else { return "–" }
        let hours = remainingMinutes / 60
        let minutes = remainingMinutes % 60
        return hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
    }

    /// Beispieldaten für den Demo-Modus (solange kein Drucker konfiguriert ist).
    static let demo: PrinterSnapshot = {
        var s = PrinterSnapshot()
        s.taskName = "Benchy.3mf"
        s.activity = .printing
        s.progressPercent = 49
        s.remainingMinutes = 67
        s.currentLayer = 50
        s.totalLayers = 125
        s.nozzleTemp = 41
        s.nozzleTarget = 25
        s.bedTemp = 55
        s.bedTarget = 55
        s.chamberTemp = 29.1
        s.amsUnits = [
            AMSUnit(id: "0", humidityText: "26%", temperature: 29.1, trays: [
                FilamentTray(id: "A1", material: "PLA Matte", colorHex: "9B6A3CFF", remainPercent: 89),
                FilamentTray(id: "A2", material: "PLA Basic", colorHex: "6A3CE8FF", remainPercent: 100),
                FilamentTray(id: "A3", material: "PLA Basic", colorHex: "F4E838FF", remainPercent: 100),
                FilamentTray(id: "A4", material: "PLA", colorHex: "E83838FF", remainPercent: nil),
            ]),
        ]
        s.externalSpool = FilamentTray(id: "EXT", material: "PLA", colorHex: "F2E6D0FF", remainPercent: nil)
        s.activeTrayID = "EXT"
        return s
    }()
}

extension Color {
    /// Erzeugt eine Farbe aus einem RGBA-Hex-String wie "FFAA00FF" (Bambu-Format).
    init?(rgbaHex: String) {
        var hex = rgbaHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let r, g, b, a: Double
        if hex.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
