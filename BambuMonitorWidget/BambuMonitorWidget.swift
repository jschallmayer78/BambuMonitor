//
//  BambuMonitorWidget.swift
//  BambuMonitorWidget
//
//  Desktop-Widget mit dem aktuellen Druckstatus. Die Daten schreibt die
//  Haupt-App bei jeder Statusänderung in die App Group und stößt per
//  WidgetCenter einen Timeline-Reload an.
//

import WidgetKit
import SwiftUI

/// Strukturgleiche Kopie von `WidgetSnapshot` aus der Haupt-App –
/// Änderungen dort müssen hier nachgezogen werden.
struct SharedSnapshot: Codable {
    static let appGroupID = "group.Meine.BambuMonitor"
    static let storageKey = "widgetSnapshot"

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

    static let demo = SharedSnapshot(
        printerName: "Bambu Drucker",
        activityRaw: "RUNNING",
        progressPercent: 49,
        remainingMinutes: 67,
        currentLayer: 50,
        totalLayers: 125,
        taskName: "Benchy.3mf",
        updatedAt: .now
    )

    static func load() -> SharedSnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(SharedSnapshot.self, from: data)
    }
}

struct PrinterEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> PrinterEntry {
        PrinterEntry(date: .now, snapshot: .demo)
    }

    func getSnapshot(in context: Context, completion: @escaping (PrinterEntry) -> Void) {
        completion(PrinterEntry(date: .now, snapshot: SharedSnapshot.load() ?? .demo))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PrinterEntry>) -> Void) {
        let entry = PrinterEntry(date: .now, snapshot: SharedSnapshot.load())
        // Die App lädt die Timeline bei Änderungen aktiv neu – das Intervall
        // ist nur ein Fallback, falls die App nicht läuft.
        let refresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }
}

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
                Text("Keine Daten – BambuMonitor starten")
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
            }
            Spacer(minLength: 0)
            Text("\(snapshot.progressPercent)%")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6)
            ProgressView(value: Double(snapshot.progressPercent), total: 100)
                .tint(snapshot.activityColor)
            if snapshot.isPrinting {
                Label(snapshot.remainingText, systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(snapshot.printerName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
                    Label(snapshot.remainingText, systemImage: "clock")
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

struct BambuMonitorWidget: Widget {
    let kind: String = "BambuMonitorWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            BambuMonitorWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(red: 0.08, green: 0.10, blue: 0.18)
                }
                .environment(\.colorScheme, .dark)
                .foregroundStyle(.white)
        }
        .configurationDisplayName("Bambu Drucker")
        .description("Zeigt den aktuellen Status deines Bambu Lab Druckers.")
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
