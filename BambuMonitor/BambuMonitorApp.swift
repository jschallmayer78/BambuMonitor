//
//  BambuMonitorApp.swift
//  BambuMonitor
//
//  Menüleisten-App zum Überwachen eines Bambu Lab 3D-Druckers.
//

import SwiftUI
import Sparkle

@main
struct BambuMonitorApp: App {
    @State private var monitor = PrinterMonitor()
    /// Sparkle-Updater; startet beim App-Start und prüft periodisch auf Updates.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        MenuBarExtra {
            MenuBarStatusView(monitor: monitor, updater: updaterController.updater)
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
