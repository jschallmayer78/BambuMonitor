//
//  WidgetSnapshot.swift
//  BambuMonitor
//
//  Kompakter Druckerzustand für das Desktop-Widget. Wird über die
//  App Group (UserDefaults-Suite) zwischen App und Widget-Extension geteilt.
//  Achtung: Die Widget-Extension hält eine strukturgleiche Kopie –
//  Änderungen hier müssen dort nachgezogen werden.
//

import Foundation

struct WidgetSnapshot: Codable {
    // Team-ID-Präfix statt "group." – nötig für Developer-ID-Verteilung
    // außerhalb des App Store (macOS-Konvention).
    static let appGroupID = "J3P8T7BG24.BambuMonitor"
    static let storageKey = "widgetSnapshot"

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
