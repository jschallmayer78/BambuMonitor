//
//  BackgroundRefresh.swift
//  PrintMonMobile
//
//  "Push"-Ersatz ohne Server: iOS weckt die App periodisch im Hintergrund
//  (Background App Refresh), sie verbindet sich kurz mit allen Druckern
//  und meldet abgeschlossene oder fehlgeschlagene Drucke als lokale
//  Mitteilung. Funktioniert nur im selben Netzwerk wie die Drucker;
//  den Zeitpunkt bestimmt iOS (typisch alle 15+ Minuten, opportunistisch).
//

import Foundation
import BackgroundTasks
import UserNotifications

@MainActor
enum BackgroundRefresh {
    static let taskIdentifier = "Meine.PrintMonMobile.refresh"
    private static let lastActivitiesKey = "backgroundLastActivities"

    /// Muss vor Abschluss des App-Starts aufgerufen werden (App.init).
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await handle(refreshTask)
            }
        }
    }

    static func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) async {
        schedule() // nächsten Lauf gleich wieder anmelden

        // Doppeltes setTaskCompleted (Ablauf + normales Ende) vermeiden.
        final class CompletionGuard: @unchecked Sendable {
            var isCompleted = false
        }
        let completion = CompletionGuard()
        task.expirationHandler = {
            guard !completion.isCompleted else { return }
            completion.isCompleted = true
            task.setTaskCompleted(success: false)
        }

        // Eigener Monitor für diesen Hintergrund-Lauf: verbindet alle
        // Drucker; nach kurzer Wartezeit liegen die Snapshots vor.
        let monitor = PrinterMonitor()
        try? await Task.sleep(for: .seconds(12))
        checkTransitions(monitor: monitor)
        monitor.disconnect()

        guard !completion.isCompleted else { return }
        completion.isCompleted = true
        task.setTaskCompleted(success: true)
    }

    /// Vergleicht die aktuellen Aktivitäten mit dem letzten bekannten Stand
    /// und meldet Übergänge von "druckt/pausiert" zu "fertig/fehlgeschlagen".
    static func checkTransitions(monitor: PrinterMonitor) {
        let defaults = UserDefaults.standard
        var last = defaults.dictionary(forKey: lastActivitiesKey) as? [String: String] ?? [:]

        for config in monitor.printers {
            guard let snapshot = monitor.snapshots[config.id] else { continue }
            let key = config.id.uuidString
            let previous = last[key]

            if previous == PrinterActivity.printing.rawValue || previous == PrinterActivity.paused.rawValue {
                let body = snapshot.taskName.isEmpty ? config.name : "\(snapshot.taskName) auf \(config.name)"
                switch snapshot.activity {
                case .finished:
                    PrinterMonitor.postNotification(title: "Druck abgeschlossen", body: body)
                case .failed:
                    PrinterMonitor.postNotification(title: "Druck fehlgeschlagen", body: body)
                default:
                    break
                }
            }
            last[key] = snapshot.activity.rawValue
        }
        defaults.set(last, forKey: lastActivitiesKey)
    }

    /// Beim Wechsel in den Hintergrund den aktuellen Stand merken, damit
    /// der nächste Hintergrund-Lauf keine bereits gesehenen Übergänge
    /// doppelt meldet.
    static func syncLastActivities(monitor: PrinterMonitor) {
        let defaults = UserDefaults.standard
        var last = defaults.dictionary(forKey: lastActivitiesKey) as? [String: String] ?? [:]
        for config in monitor.printers {
            if let snapshot = monitor.snapshots[config.id] {
                last[config.id.uuidString] = snapshot.activity.rawValue
            }
        }
        defaults.set(last, forKey: lastActivitiesKey)
    }
}
