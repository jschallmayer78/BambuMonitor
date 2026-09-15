//
//  PrintMonMobileApp.swift
//  PrintMonMobile
//
//  iPhone-Version von Joe's 3D PrintMon: nutzt dieselben Treiber und
//  Modelle wie die macOS-Menüleisten-App.
//

import SwiftUI

@main
struct PrintMonMobileApp: App {
    @State private var monitor = PrinterMonitor()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(monitor: monitor)
        }
        .onChange(of: scenePhase) { _, phase in
            // Im Hintergrund trennen (spart Akku und Drucker-Verbindungen),
            // beim Zurückkehren neu verbinden.
            switch phase {
            case .active:
                if monitor.isConfigured { monitor.connect() }
            case .background:
                monitor.disconnect()
            default:
                break
            }
        }
    }
}
