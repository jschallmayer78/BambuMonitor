//
//  WidgetSnapshot.swift
//  BambuMonitor
//
//  Datenaustausch zwischen App und Widgets über die App Group:
//  pro Drucker ein Snapshot plus eine Drucker-Liste für die
//  Widget-Konfiguration. Die Widget-Extensions halten strukturgleiche
//  Kopien dieser Typen – Änderungen dort nachziehen.
//

import Foundation

/// Eintrag der Drucker-Liste, aus der das Widget seine Auswahl anbietet.
struct WidgetPrinterInfo: Codable, Identifiable {
    var id: String   // UUID-String der PrinterConfig
    var name: String
}

struct WidgetSnapshot: Codable {
    /// macOS (Developer-ID-Verteilung) verlangt das Team-ID-Präfix,
    /// iOS zwingend das "group."-Präfix. Mac- und iOS-Seite teilen keine
    /// Daten untereinander – nur App ↔ Widget auf derselben Plattform.
    #if os(macOS)
    static let appGroupID = "J3P8T7BG24.BambuMonitor"
    #else
    static let appGroupID = "group.Meine.BambuMonitor"
    #endif

    static let printerListKey = "widgetPrinters"
    static let activePrinterKey = "widgetActivePrinterID"

    static func storageKey(for printerID: String) -> String {
        "widgetSnapshot-\(printerID)"
    }

    var printerName: String
    var activityRaw: String
    var progressPercent: Int
    var remainingMinutes: Int
    var currentLayer: Int
    var totalLayers: Int
    var taskName: String
    var updatedAt: Date
}

extension WidgetSnapshot {
    init(from snapshot: PrinterSnapshot, printerName: String) {
        self.init(
            printerName: printerName,
            activityRaw: snapshot.activity.rawValue,
            progressPercent: snapshot.progressPercent,
            remainingMinutes: snapshot.remainingMinutes,
            currentLayer: snapshot.currentLayer,
            totalLayers: snapshot.totalLayers,
            taskName: snapshot.taskName,
            updatedAt: Date()
        )
    }
}
