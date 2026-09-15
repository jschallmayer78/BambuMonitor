//
//  BambuMonitorWidget.swift
//  BambuMonitorWidget
//
//  Widget mit Druckerstatus – per Konfiguration (langes Drücken →
//  "Widget bearbeiten") lässt sich der angezeigte Drucker wählen;
//  ohne Auswahl zeigt es den in der App aktiven Drucker. Wird auf
//  macOS und iOS von den jeweiligen Widget-Targets kompiliert.
//

import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Geteilte Daten (strukturgleiche Kopie aus der App)

/// Kopie von `WidgetPrinterInfo` aus der Haupt-App.
struct SharedPrinterInfo: Codable, Identifiable {
    var id: String
    var name: String
}

/// Strukturgleiche Kopie von `WidgetSnapshot` aus der Haupt-App –
/// Änderungen dort müssen hier nachgezogen werden.
struct SharedSnapshot: Codable {
    #if os(macOS)
    static let appGroupID = "J3P8T7BG24.BambuMonitor"
    #else
    static let appGroupID = "group.Meine.BambuMonitor"
    #endif
    static let printerListKey = "widgetPrinters"
    static let activePrinterKey = "widgetActivePrinterID"

    var printerName: String
    var activityRaw: String
    var progressPercent: Int
    var remainingMinutes: Int
    var currentLayer: Int
    var totalLayers: Int
    var taskName: String
    var updatedAt: Date

    var isPrinting: Bool { activityRaw == "RUNNING" || activityRaw == "PAUSE" }

    var activityText: String {
        switch activityRaw {
        case "RUNNING": return "Druckt"
        case "PAUSE": return "Pausiert"
        case "FINISH": return "Fertig"
        case "FAILED": return "Fehlgeschlagen"
        case "PREPARE": return "Vorbereitung"
        case "SLICING": return "Slicing"
        case "IDLE": return "Bereit"
        default: return "Unbekannt"
        }
    }

    var activityColor: Color {
        switch activityRaw {
        case "RUNNING": return .blue
        case "PAUSE": return .orange
        case "FINISH": return .green
        case "FAILED": return .red
        default: return .gray
        }
    }

    var remainingText: String {
        guard remainingMinutes > 0 else { return "–" }
        let hours = remainingMinutes / 60
        let minutes = remainingMinutes % 60
        return hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
    }

    /// Voraussichtliches Druckende – wird im Widget als live
    /// herunterzählender Countdown gerendert (keine Reloads nötig).
    var estimatedEnd: Date? {
        guard isPrinting, remainingMinutes > 0 else { return nil }
        return updatedAt.addingTimeInterval(TimeInterval(remainingMinutes * 60))
    }

    static let demo = SharedSnapshot(
        printerName: "3D-Drucker",
        activityRaw: "RUNNING",
        progressPercent: 49,
        remainingMinutes: 67,
        currentLayer: 50,
        totalLayers: 125,
        taskName: "Benchy.3mf",
        updatedAt: .now
    )

    static func printerList() -> [SharedPrinterInfo] {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: printerListKey),
              let list = try? JSONDecoder().decode([SharedPrinterInfo].self, from: data) else { return [] }
        return list
    }

    /// Lädt den Snapshot des gewünschten Druckers; ohne Auswahl den des
    /// in der App aktiven Druckers.
    static func load(printerID: String?) -> SharedSnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return nil }
        let id = printerID ?? defaults.string(forKey: activePrinterKey)
        guard let id, let data = defaults.data(forKey: "widgetSnapshot-\(id)") else { return nil }
        return try? JSONDecoder().decode(SharedSnapshot.self, from: data)
    }
}

// MARK: - Widget-Konfiguration (Drucker-Auswahl)

struct PrinterEntity: AppEntity {
    var id: String
    var name: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Drucker"
    static let defaultQuery = PrinterEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct PrinterEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PrinterEntity] {
        SharedSnapshot.printerList()
            .filter { identifiers.contains($0.id) }
            .map { PrinterEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [PrinterEntity] {
        SharedSnapshot.printerList().map { PrinterEntity(id: $0.id, name: $0.name) }
    }
}

struct SelectPrinterIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Drucker auswählen"
    static let description = IntentDescription("Wählt den Drucker, den dieses Widget anzeigt.")

    /// Ohne Auswahl zeigt das Widget den in der App aktiven Drucker.
    @Parameter(title: "Drucker")
    var printer: PrinterEntity?
}

// MARK: - Timeline

struct PrinterEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedSnapshot?
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PrinterEntry {
        PrinterEntry(date: .now, snapshot: .demo)
    }

    func snapshot(for configuration: SelectPrinterIntent, in context: Context) async -> PrinterEntry {
        PrinterEntry(date: .now, snapshot: SharedSnapshot.load(printerID: configuration.printer?.id) ?? .demo)
    }

    func timeline(for configuration: SelectPrinterIntent, in context: Context) async -> Timeline<PrinterEntry> {
        let snapshot = SharedSnapshot.load(printerID: configuration.printer?.id)
        let entry = PrinterEntry(date: .now, snapshot: snapshot)
        // Die App lädt die Timeline bei Änderungen aktiv neu – das Intervall
        // ist nur ein Fallback. Zum voraussichtlichen Druckende zusätzlich
        // aktualisieren, damit der Countdown nicht ins Negative läuft.
        var refresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        if let end = snapshot?.estimatedEnd, end > .now, end < refresh {
            refresh = end.addingTimeInterval(30)
        }
        return Timeline(entries: [entry], policy: .after(refresh))
    }
}

// MARK: - Ansichten

struct BambuMonitorWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: PrinterEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .systemMedium:
                MediumView(snapshot: snapshot)
            default:
                SmallView(snapshot: snapshot)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "printer.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Keine Daten – App starten")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

private struct SmallView: View {
    var snapshot: SharedSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle()
                    .fill(snapshot.activityColor)
                    .frame(width: 7, height: 7)
                Text(snapshot.activityText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(snapshot.printerName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(snapshot.progressPercent)%")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6)
            ProgressView(value: Double(snapshot.progressPercent), total: 100)
                .tint(snapshot.activityColor)
            if let end = snapshot.estimatedEnd, end > .now {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                    Text(end, style: .relative) // zählt live herunter
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else if snapshot.isPrinting {
                Label(snapshot.remainingText, systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MediumView: View {
    var snapshot: SharedSnapshot

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.printerName)
                    .font(.headline)
                    .lineLimit(1)
                if !snapshot.taskName.isEmpty {
                    Text(snapshot.taskName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(snapshot.activityColor)
                        .frame(width: 7, height: 7)
                    Text(snapshot.activityText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                ProgressView(value: Double(snapshot.progressPercent), total: 100)
                    .tint(snapshot.activityColor)
                HStack(spacing: 12) {
                    if let end = snapshot.estimatedEnd, end > .now {
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                            Text(end, style: .relative) // zählt live herunter
                        }
                    } else {
                        Label(snapshot.remainingText, systemImage: "clock")
                    }
                    if snapshot.totalLayers > 0 {
                        Label("\(snapshot.currentLayer)/\(snapshot.totalLayers)", systemImage: "square.3.layers.3d")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Text("\(snapshot.progressPercent)%")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Widget

struct BambuMonitorWidget: Widget {
    let kind: String = "BambuMonitorWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectPrinterIntent.self, provider: Provider()) { entry in
            BambuMonitorWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(red: 0.08, green: 0.10, blue: 0.18)
                }
                .environment(\.colorScheme, .dark)
                .foregroundStyle(.white)
        }
        .configurationDisplayName("Joe's 3D PrintMon")
        .description("Zeigt den Status eines wählbaren 3D-Druckers.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview(as: .systemSmall) {
    BambuMonitorWidget()
} timeline: {
    PrinterEntry(date: .now, snapshot: .demo)
}

#Preview(as: .systemMedium) {
    BambuMonitorWidget()
} timeline: {
    PrinterEntry(date: .now, snapshot: .demo)
}
