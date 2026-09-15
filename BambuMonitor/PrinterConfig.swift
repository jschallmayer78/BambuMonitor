//
//  PrinterConfig.swift
//  BambuMonitor
//
//  Konfiguration eines überwachten Druckers. Die App unterstützt mehrere
//  Drucker verschiedener Hersteller; einer davon ist aktiv und wird in
//  Menüleiste, Popover und Widget angezeigt.
//

import Foundation

enum PrinterKind: String, Codable, CaseIterable {
    case bambu
    case snapmakerU1

    var displayName: String {
        switch self {
        case .bambu: return "Bambu Lab"
        case .snapmakerU1: return "Snapmaker U1"
        }
    }

    var defaultPrinterName: String {
        switch self {
        case .bambu: return "Bambu Drucker"
        case .snapmakerU1: return "Snapmaker U1"
        }
    }
}

struct PrinterConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: PrinterKind
    var name: String
    var host: String = ""
    /// Nur Bambu Lab: Seriennummer für die MQTT-Topics.
    var serial: String = ""

    /// Sind alle nötigen Felder ausgefüllt? Der Bambu-Access-Code liegt im
    /// Keychain und wird separat geprüft.
    var isComplete: Bool {
        switch kind {
        case .bambu: return !host.isEmpty && !serial.isEmpty
        case .snapmakerU1: return !host.isEmpty
        }
    }
}
