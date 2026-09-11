//
//  MenuBarStatusView.swift
//  BambuMonitor
//
//  Das Popover der Menüleisten-App: Status-Karte, Filament-Übersicht
//  und Verbindungseinstellungen im dunklen Karten-Design.
//

import SwiftUI
import AppKit
import Sparkle

private enum Theme {
    static let background = Color(red: 0.08, green: 0.10, blue: 0.18)
    static let card = Color(red: 0.12, green: 0.15, blue: 0.24)
    static let innerCard = Color(red: 0.16, green: 0.19, blue: 0.29)
    static let border = Color.white.opacity(0.08)
    static let accent = Color(red: 0.30, green: 0.52, blue: 1.0)
    static let secondaryText = Color.white.opacity(0.55)
}

struct MenuBarStatusView: View {
    @Bindable var monitor: PrinterMonitor
    var updater: SPUUpdater?
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if monitor.isDemoMode {
                    demoBanner
                }
                StatusCard(monitor: monitor)
                if monitor.isConfigured {
                    CameraCard(monitor: monitor)
                        .id(monitor.printerHost + monitor.accessCode)
                }
                FilamentsCard(snapshot: monitor.snapshot)
                ConnectionCard(monitor: monitor, showSettings: $showSettings)
                footer
            }
            .padding(14)
        }
        // MenuBarExtra-Fenster kollabieren ohne explizite Höhe, weil die
        // ScrollView keine intrinsische Höhe meldet.
        .frame(width: 400, height: 640)
        .background(Theme.background)
        .environment(\.colorScheme, .dark)
    }

    private var demoBanner: some View {
        Label("Demo-Modus – unten Drucker konfigurieren", systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            if let lastUpdate = monitor.lastUpdate {
                Text("Aktualisiert \(lastUpdate.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if let updater {
                Button("Nach Updates suchen") {
                    // Die Update-Fenster von Sparkle brauchen eine aktive App –
                    // als Menüleisten-App ist sie das sonst nicht.
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    updater.checkForUpdates()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            }
            Button("Beenden") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Theme.secondaryText)
        }
        .padding(.top, 2)
    }
}

// MARK: - Status-Karte

private struct StatusCard: View {
    var monitor: PrinterMonitor

    private var snapshot: PrinterSnapshot { monitor.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(monitor.printerName)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text(snapshot.activity.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(snapshot.progressPercent)%")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(snapshot.activity.displayName)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }

            HStack {
                statusBadge
                Spacer()
                Button {
                    monitor.refresh()
                } label: {
                    Label("Aktualisieren", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PillButtonStyle())
                Button {
                    openBambuStudio()
                } label: {
                    Label("Bambu Studio", systemImage: "square.grid.2x2")
                }
                .buttonStyle(PillButtonStyle())
            }

            ProgressView(value: Double(snapshot.progressPercent), total: 100)
                .progressViewStyle(.linear)
                .tint(Theme.accent)

            HStack(spacing: 10) {
                InfoChip(icon: "clock", title: "Restzeit", value: snapshot.remainingText)
                InfoChip(icon: "square.3.layers.3d", title: "Schicht",
                         value: snapshot.totalLayers > 0 ? "\(snapshot.currentLayer) / \(snapshot.totalLayers)" : "–")
            }

            VStack(alignment: .leading, spacing: 3) {
                if !snapshot.taskName.isEmpty {
                    Text(snapshot.taskName)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                Text("Düse \(Int(snapshot.nozzleTemp)) / \(Int(snapshot.nozzleTarget))°  ·  Bett \(Int(snapshot.bedTemp)) / \(Int(snapshot.bedTarget))°")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                if let chamber = snapshot.chamberTemp {
                    Text("Bauraum \(chamber, format: .number.precision(.fractionLength(1)))°")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .padding(16)
        .cardBackground()
    }

    private var statusBadge: some View {
        Label(snapshot.activity.displayName, systemImage: snapshot.activity == .printing ? "play.fill" : "circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(snapshot.activity.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(snapshot.activity.color.opacity(0.15), in: Capsule())
    }

    private func openBambuStudio() {
        let workspace = NSWorkspace.shared
        if let url = workspace.urlForApplication(withBundleIdentifier: "com.bambulab.bambu-studio") {
            workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

// MARK: - Kamera-Karte

/// Zeigt das Live-Bild der Druckerkamera. Der Stream läuft nur, solange
/// das Popover geöffnet ist.
private struct CameraCard: View {
    var monitor: PrinterMonitor
    @State private var frame: NSImage?
    @State private var statusText = "Kamera wird verbunden…"
    @State private var rtspClient: BambuRTSPCameraClient?
    @State private var jpegClient: BambuCameraClient?
    @State private var isVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kamera")
                .font(.headline)
                .foregroundStyle(.white)

            ZStack {
                if let frame {
                    Image(nsImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.innerCard)
                        .frame(height: 200)
                        .overlay(
                            VStack(spacing: 6) {
                                Image(systemName: "video")
                                    .font(.title2)
                                    .foregroundStyle(Theme.secondaryText)
                                Text(statusText)
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.horizontal, 12)
                        )
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .onAppear(perform: startStream)
        .onDisappear(perform: stopStream)
    }

    private func startStream() {
        isVisible = true
        startRTSPStream()
    }

    /// X1-, H2- und P2-Modelle streamen H.264 per RTSPS auf Port 322.
    private func startRTSPStream() {
        let client = BambuRTSPCameraClient(host: monitor.printerHost, accessCode: monitor.accessCode)
        rtspClient = client
        client.onFrame = { image in
            frame = image
        }
        client.onError = { _ in
            rtspClient?.stop()
            rtspClient = nil
            if frame == nil {
                // RTSP nicht verfügbar → JPEG-Protokoll der P1-/A1-Serie versuchen.
                startJPEGStream()
            } else {
                restartAfterDelay()
            }
        }
        client.start()
    }

    /// P1- und A1-Modelle liefern JPEG-Frames auf Port 6000.
    private func startJPEGStream() {
        let client = BambuCameraClient(host: monitor.printerHost, accessCode: monitor.accessCode)
        jpegClient = client
        client.onFrame = { image in
            frame = image
        }
        client.onError = { message in
            jpegClient?.stop()
            jpegClient = nil
            if frame == nil {
                statusText = "\(message)\nAm Drucker muss „LAN-Liveview“ aktiviert sein."
            } else {
                restartAfterDelay()
            }
        }
        client.start()
    }

    /// Verbindung mitten im Stream verloren → kurz warten und neu aufbauen.
    private func restartAfterDelay() {
        frame = nil
        statusText = "Verbindung verloren – neuer Versuch…"
        Task {
            try? await Task.sleep(for: .seconds(2))
            if isVisible && rtspClient == nil && jpegClient == nil {
                startRTSPStream()
            }
        }
    }

    private func stopStream() {
        isVisible = false
        rtspClient?.stop()
        rtspClient = nil
        jpegClient?.stop()
        jpegClient = nil
    }
}

// MARK: - Filament-Karte

private struct FilamentsCard: View {
    var snapshot: PrinterSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filamente")
                .font(.headline)
                .foregroundStyle(.white)

            if snapshot.amsUnits.isEmpty && snapshot.externalSpool == nil {
                Text("Keine Filament-Daten verfügbar")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }

            ForEach(snapshot.amsUnits) { unit in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(unit.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.8))
                        if let humidity = unit.humidityText {
                            Label(humidity, systemImage: "drop.fill")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        if let temp = unit.temperature {
                            Label("\(temp, format: .number.precision(.fractionLength(1)))°", systemImage: "thermometer.medium")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    HStack(spacing: 8) {
                        ForEach(unit.trays) { tray in
                            TrayView(tray: tray, isActive: isTrayActive(tray, in: unit))
                        }
                    }
                }
            }

            if let spool = snapshot.externalSpool {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Externe Spule")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    TrayView(tray: spool, isActive: snapshot.activeTrayID == "254")
                        .frame(maxWidth: 90)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    /// `tray_now` ist ein globaler Slot-Index über alle AMS-Module (0–3 = AMS A usw.).
    private func isTrayActive(_ tray: FilamentTray, in unit: AMSUnit) -> Bool {
        guard let activeID = snapshot.activeTrayID, let active = Int(activeID), active < 254,
              let unitIndex = Int(unit.id),
              let slotNumber = Int(tray.id.dropFirst()) else { return false }
        return active == unitIndex * 4 + (slotNumber - 1)
    }
}

private struct TrayView: View {
    var tray: FilamentTray
    var isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Capsule()
                .fill(tray.color)
                .frame(height: 14)
            Text(tray.id)
                .font(.caption2)
                .foregroundStyle(Theme.secondaryText)
            Text(tray.material)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2, reservesSpace: true)
            Spacer(minLength: 0)
            Text(tray.remainPercent.map { "\($0)%" } ?? "–")
                .font(.caption2)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background(Theme.innerCard, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isActive ? Theme.accent : Theme.border, lineWidth: isActive ? 1.5 : 1)
        )
    }
}

// MARK: - Verbindungs-Karte

private struct ConnectionCard: View {
    @Bindable var monitor: PrinterMonitor
    @Binding var showSettings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Drucker-Verbindung")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: showSettings ? "chevron.up" : "gearshape")
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(monitor.status.displayText)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                if !monitor.printerSerial.isEmpty {
                    Text(monitor.printerSerial)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.secondaryText)
                }
            }

            if showSettings || !monitor.isConfigured {
                settingsForm
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private var statusColor: Color {
        switch monitor.status {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .red
        case .notConfigured: return .gray
        }
    }

    private var settingsForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsField(label: "Name", placeholder: "z. B. X1 Carbon", text: $monitor.printerName)
            SettingsField(label: "IP-Adresse", placeholder: "192.168.1.100", text: $monitor.printerHost)
            SettingsField(label: "Seriennummer", placeholder: "01S00A123456789", text: $monitor.printerSerial)
            SettingsField(label: "Access Code", placeholder: "LAN-Zugangscode", text: $monitor.accessCode)

            Text("IP und Access Code findest du am Drucker unter Einstellungen → Netzwerk (LAN-Modus).")
                .font(.caption2)
                .foregroundStyle(Theme.secondaryText)

            Button {
                monitor.connect()
                showSettings = false
            } label: {
                Text("Verbinden")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(!monitor.isConfigured)
        }
        .padding(.top, 4)
    }
}

private struct SettingsField: View {
    var label: String
    var placeholder: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 96, alignment: .leading)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
        }
    }
}

// MARK: - Bausteine

private struct InfoChip: View {
    var icon: String
    var title: String
    var value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Theme.secondaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
                Text(value)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.innerCard, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border))
    }
}

private struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.innerCard.opacity(configuration.isPressed ? 0.6 : 1), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border))
    }
}

private extension View {
    func cardBackground() -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }
}

#Preview {
    MenuBarStatusView(monitor: PrinterMonitor())
}
