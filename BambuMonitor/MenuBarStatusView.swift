//
//  MenuBarStatusView.swift
//  BambuMonitor
//
//  Das Popover der Menüleisten-App: Drucker-Umschalter, Status-Karte,
//  Kamera, Filament-Übersicht und Drucker-Verwaltung im dunklen
//  Karten-Design.
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
                if monitor.printers.count > 1 {
                    printerSwitcher
                }
                StatusCard(monitor: monitor)
                if monitor.isConfigured, let config = monitor.activeConfig {
                    CameraCard(monitor: monitor)
                        .id("\(config.id)-\(config.host)-\(monitor.activeAccessCode)")
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

    private var printerSwitcher: some View {
        Picker("Drucker", selection: Binding(
            get: { monitor.activePrinterID },
            set: { if let id = $0 { monitor.selectPrinter(id) } }
        )) {
            ForEach(monitor.printers) { printer in
                Text(printer.name).tag(Optional(printer.id))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
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
                    Text(monitor.activeConfig?.name ?? "Kein Drucker")
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
                if monitor.activeConfig?.kind == .bambu {
                    Button {
                        openBambuStudio()
                    } label: {
                        Label("Bambu Studio", systemImage: "square.grid.2x2")
                    }
                    .buttonStyle(PillButtonStyle())
                }
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

/// Zeigt das Live-Bild der Druckerkamera; ein Klick darauf öffnet den
/// Stream größer in einem eigenen Fenster. Der Karten-Stream läuft nur,
/// solange das Popover geöffnet ist.
private struct CameraCard: View {
    var monitor: PrinterMonitor
    @State private var stream = CameraStreamController()
    @State private var isHovering = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Kamera")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text("Klicken zum Vergrößern")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
                    .opacity(stream.frame != nil ? 1 : 0)
            }

            ZStack(alignment: .bottomTrailing) {
                if let frame = stream.frame {
                    Image(nsImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(isHovering ? 1 : 0.6))
                        .padding(6)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.innerCard)
                        .frame(height: 200)
                        .overlay(
                            VStack(spacing: 6) {
                                Image(systemName: "video")
                                    .font(.title2)
                                    .foregroundStyle(Theme.secondaryText)
                                Text(stream.statusText)
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.horizontal, 12)
                        )
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onHover { isHovering = $0 }
            .onTapGesture(perform: openCameraWindow)
            .help("Livestream in eigenem Fenster öffnen")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .onAppear(perform: startStream)
        .onDisappear(perform: stream.stop)
    }

    private func startStream() {
        guard let config = monitor.activeConfig else { return }
        stream.start(config: config, accessCode: monitor.activeAccessCode)
    }

    private func openCameraWindow() {
        // Als Menüleisten-App muss die App aktiv sein, damit das Fenster
        // im Vordergrund erscheint.
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "camera")
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
                            TrayView(tray: tray, isActive: tray.id == snapshot.activeTrayID)
                        }
                    }
                }
            }

            if let spool = snapshot.externalSpool {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Externe Spule")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    TrayView(tray: spool, isActive: spool.id == snapshot.activeTrayID)
                        .frame(maxWidth: 90)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
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

// MARK: - Drucker-Verwaltung

private struct ConnectionCard: View {
    @Bindable var monitor: PrinterMonitor
    @Binding var showSettings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Drucker")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Menu {
                    ForEach(PrinterKind.allCases, id: \.self) { kind in
                        Button("\(kind.displayName) hinzufügen") {
                            monitor.addPrinter(kind: kind)
                            showSettings = true
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Theme.secondaryText)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
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
                if let kind = monitor.activeConfig?.kind {
                    Text("· \(kind.displayName)")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                if let serial = monitor.activeConfig?.serial, !serial.isEmpty {
                    Text(serial)
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

    @ViewBuilder
    private var settingsForm: some View {
        if let config = monitor.activeConfig {
            VStack(alignment: .leading, spacing: 8) {
                SettingsField(label: "Name", placeholder: config.kind.defaultPrinterName, text: configField(\.name))
                SettingsField(label: "IP-Adresse", placeholder: "192.168.1.100", text: configField(\.host))

                if config.kind == .bambu {
                    SettingsField(label: "Seriennummer", placeholder: "01S00A123456789", text: configField(\.serial))
                    SettingsField(label: "Access Code", placeholder: "LAN-Zugangscode", text: $monitor.activeAccessCode)
                    Text("IP und Access Code findest du am Drucker unter Einstellungen → Netzwerk (LAN-Modus).")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    Text("Es reicht die IP-Adresse des U1 im lokalen Netzwerk (am Drucker unter Einstellungen → Netzwerk).")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryText)
                }

                HStack {
                    Button(role: .destructive) {
                        monitor.removeActivePrinter()
                    } label: {
                        Text("Entfernen")
                    }
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
            }
            .padding(.top, 4)
        } else {
            Text("Über „+“ einen Drucker hinzufügen.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private func configField(_ keyPath: WritableKeyPath<PrinterConfig, String>) -> Binding<String> {
        Binding(
            get: { monitor.activeConfig?[keyPath: keyPath] ?? "" },
            set: { newValue in monitor.updateActiveConfig { $0[keyPath: keyPath] = newValue } }
        )
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
