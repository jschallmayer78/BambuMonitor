//
//  ContentView.swift
//  PrintMonMobile
//
//  Hauptansicht der iPhone-App: Status, Kamera (Tipp → Vollbild),
//  Filamente und Drucker-Verwaltung im dunklen Karten-Design der Mac-App.
//

import SwiftUI

private enum Theme {
    static let background = Color(red: 0.08, green: 0.10, blue: 0.18)
    static let card = Color(red: 0.12, green: 0.15, blue: 0.24)
    static let innerCard = Color(red: 0.16, green: 0.19, blue: 0.29)
    static let border = Color.white.opacity(0.08)
    static let accent = Color(red: 0.30, green: 0.52, blue: 1.0)
    static let secondaryText = Color.white.opacity(0.55)
}

struct ContentView: View {
    @Bindable var monitor: PrinterMonitor
    @State private var showSettings = false
    @State private var showFullscreenCamera = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if monitor.isDemoMode {
                        Label("Demo-Modus – über das Zahnrad Drucker konfigurieren", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if monitor.printers.count > 1 {
                        printerSwitcher
                    }
                    StatusCard(monitor: monitor)
                    if monitor.isConfigured {
                        CameraCard(monitor: monitor, showFullscreen: $showFullscreenCamera)
                            .id(cameraIdentity)
                    }
                    FilamentsCard(snapshot: monitor.snapshot)
                }
                .padding(14)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(monitor.activeConfig?.name ?? "Joe's 3D PrintMon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        monitor.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet(monitor: monitor)
            }
            .fullScreenCover(isPresented: $showFullscreenCamera) {
                FullscreenCameraView(monitor: monitor)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var cameraIdentity: String {
        guard let config = monitor.activeConfig else { return "none" }
        return "\(config.id)-\(config.host)-\(monitor.activeAccessCode)"
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

            HStack(spacing: 8) {
                Label(snapshot.activity.displayName, systemImage: snapshot.activity == .printing ? "play.fill" : "circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(snapshot.activity.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(snapshot.activity.color.opacity(0.15), in: Capsule())
                Spacer()
                connectionIndicator
            }

            ProgressView(value: Double(snapshot.progressPercent), total: 100)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private var connectionIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(monitor.status.displayText)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private var statusColor: Color {
        switch monitor.status {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .red
        case .notConfigured: return .gray
        }
    }
}

// MARK: - Kamera

private struct CameraCard: View {
    var monitor: PrinterMonitor
    @Binding var showFullscreen: Bool
    @State private var stream = CameraStreamController()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Kamera")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text("Tippen zum Vergrößern")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
                    .opacity(stream.frame != nil ? 1 : 0)
            }

            ZStack(alignment: .bottomTrailing) {
                if let frame = stream.frame {
                    Image(platformImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
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
            .onTapGesture { showFullscreen = true }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .onAppear {
            if let config = monitor.activeConfig {
                stream.start(config: config, accessCode: monitor.activeAccessCode)
            }
        }
        .onDisappear(perform: stream.stop)
    }
}

/// Vollbild-Kamera – im Querformat drehen für die große Ansicht.
private struct FullscreenCameraView: View {
    var monitor: PrinterMonitor
    @State private var stream = CameraStreamController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let frame = stream.frame {
                Image(platformImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "video")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(stream.statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding()
        }
        .onAppear {
            if let config = monitor.activeConfig {
                stream.start(config: config, accessCode: monitor.activeAccessCode)
            }
        }
        .onDisappear(perform: stream.stop)
        .statusBarHidden()
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

// MARK: - Einstellungen

private struct SettingsSheet: View {
    @Bindable var monitor: PrinterMonitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Drucker") {
                    ForEach(monitor.printers) { printer in
                        Button {
                            monitor.selectPrinter(printer.id)
                        } label: {
                            HStack {
                                Text(printer.name)
                                Spacer()
                                Text(printer.kind.displayName)
                                    .foregroundStyle(.secondary)
                                if printer.id == monitor.activePrinterID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    Menu("Drucker hinzufügen") {
                        ForEach(PrinterKind.allCases, id: \.self) { kind in
                            Button(kind.displayName) {
                                monitor.addPrinter(kind: kind)
                            }
                        }
                    }
                }

                if let config = monitor.activeConfig {
                    Section("\(config.name) bearbeiten") {
                        TextField("Name", text: configField(\.name))
                        TextField("IP-Adresse", text: configField(\.host))
                            .keyboardType(.decimalPad)
                            .autocorrectionDisabled()
                        if config.kind == .bambu {
                            TextField("Seriennummer", text: configField(\.serial))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.characters)
                            SecureField("Access Code", text: $monitor.activeAccessCode)
                        } else {
                            Text("Es reicht die IP-Adresse des U1 im lokalen Netzwerk.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Verbinden") {
                            monitor.connect()
                            dismiss()
                        }
                        .disabled(!monitor.isConfigured)
                        Button("Drucker entfernen", role: .destructive) {
                            monitor.removeActivePrinter()
                        }
                    }
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }

    private func configField(_ keyPath: WritableKeyPath<PrinterConfig, String>) -> Binding<String> {
        Binding(
            get: { monitor.activeConfig?[keyPath: keyPath] ?? "" },
            set: { newValue in monitor.updateActiveConfig { $0[keyPath: keyPath] = newValue } }
        )
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

private extension View {
    func cardBackground() -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }
}

#Preview {
    ContentView(monitor: PrinterMonitor())
}
