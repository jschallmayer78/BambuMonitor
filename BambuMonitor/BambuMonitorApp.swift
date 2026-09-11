//
//  BambuMonitorApp.swift
//  BambuMonitor
//
//  Menüleisten-App zum Überwachen eines Bambu Lab 3D-Druckers.
//

import SwiftUI

@main
struct BambuMonitorApp: App {
    @State private var monitor = PrinterMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuBarStatusView(monitor: monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Kompakte Anzeige in der Menüleiste: Symbol plus Fortschritt und Restzeit,
/// solange ein Druck läuft.
private struct MenuBarLabel: View {
    var monitor: PrinterMonitor

    var body: some View {
        let snapshot = monitor.snapshot
        HStack(spacing: 4) {
            Image(systemName: "printer.fill")
            if snapshot.activity == .printing || snapshot.activity == .paused {
                Text("\(snapshot.progressPercent)% · \(snapshot.remainingText)")
            }
        }
    }
}
