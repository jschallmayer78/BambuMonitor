//
//  PrinterMonitor.swift
//  BambuMonitor
//
//  Verbindet den MQTT-Client mit der UI: verwaltet Einstellungen,
//  Verbindungsstatus und übersetzt die JSON-Reports des Druckers
//  in einen PrinterSnapshot.
//

import Foundation
import Observation
import UserNotifications
import WidgetKit

enum ConnectionStatus: Equatable {
    case notConfigured
    case connecting
    case connected
    case disconnected(String?)

    var displayText: String {
        switch self {
        case .notConfigured: return "Nicht konfiguriert"
        case .connecting: return "Verbinde…"
        case .connected: return "Verbunden"
        case .disconnected(let reason): return reason ?? "Getrennt"
        }
    }
}

@Observable
@MainActor
final class PrinterMonitor {

    // MARK: - Einstellungen (persistiert in UserDefaults)

    var printerHost: String {
        didSet { UserDefaults.standard.set(printerHost, forKey: "printerHost") }
    }
    var printerSerial: String {
        didSet { UserDefaults.standard.set(printerSerial, forKey: "printerSerial") }
    }
    var accessCode: String {
        didSet { KeychainHelper.saveAccessCode(accessCode) }
    }
    var printerName: String {
        didSet { UserDefaults.standard.set(printerName, forKey: "printerName") }
    }

    var isConfigured: Bool {
        !printerHost.isEmpty && !printerSerial.isEmpty && !accessCode.isEmpty
    }

    // MARK: - Zustand

    private(set) var snapshot = PrinterSnapshot()
    private(set) var status: ConnectionStatus = .notConfigured
    private(set) var lastUpdate: Date?

    /// Solange kein Drucker konfiguriert ist, zeigt die UI Beispieldaten.
    var isDemoMode: Bool { !isConfigured }

    @ObservationIgnored private var client: BambuMQTTClient?
    /// Bambu sendet nach dem ersten "pushall" nur noch Teil-Updates –
    /// hier wird der zusammengeführte Gesamtzustand gehalten.
    @ObservationIgnored private var mergedReport: [String: Any] = [:]
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        printerHost = defaults.string(forKey: "printerHost") ?? ""
        printerSerial = defaults.string(forKey: "printerSerial") ?? ""
        printerName = defaults.string(forKey: "printerName") ?? "Bambu Drucker"

        // Der Access Code liegt im Keychain; frühere Versionen speicherten
        // ihn in den UserDefaults – einmalig migrieren.
        if let legacy = defaults.string(forKey: "accessCode"), !legacy.isEmpty {
            KeychainHelper.saveAccessCode(legacy)
            defaults.removeObject(forKey: "accessCode")
            accessCode = legacy
        } else {
            accessCode = KeychainHelper.loadAccessCode() ?? ""
        }

        if isConfigured {
            connect()
        } else {
            snapshot = .demo
        }
    }

    // MARK: - Verbindung

    func connect() {
        guard isConfigured else {
            status = .notConfigured
            snapshot = .demo
            return
        }
        reconnectTask?.cancel()
        // Alten Client vollständig stilllegen, sonst melden dessen Callbacks
        // weiter Statusänderungen und lösen konkurrierende Reconnects aus.
        client?.onStateChange = nil
        client?.onMessage = nil
        client?.disconnect(notify: false)
        mergedReport = [:]
        snapshot = PrinterSnapshot()

        let client = BambuMQTTClient(host: printerHost, accessCode: accessCode, serial: printerSerial)
        self.client = client

        client.onStateChange = { [weak self, weak client] state in
            guard let self, let client, self.client === client else { return }
            switch state {
            case .connecting:
                self.status = .connecting
            case .connected:
                self.status = .connected
            case .disconnected(let reason):
                self.status = .disconnected(reason)
                self.scheduleReconnect()
            }
        }
        client.onMessage = { [weak self, weak client] _, payload in
            guard let self, let client, self.client === client else { return }
            self.handleReport(payload)
        }
        client.connect()
    }

    func disconnect() {
        reconnectTask?.cancel()
        client?.disconnect(notify: false)
        client = nil
        status = isConfigured ? .disconnected(nil) : .notConfigured
    }

    func refresh() {
        if status == .connected {
            client?.requestFullStatus()
        } else {
            connect()
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    // MARK: - Report-Verarbeitung

    private func handleReport(_ payload: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let printUpdate = json["print"] as? [String: Any] else { return }

        var merged = mergedReport
        Self.deepMerge(&merged, printUpdate)
        mergedReport = merged
        lastUpdate = Date()
        let previousActivity = snapshot.activity
        snapshot = Self.parseSnapshot(from: merged)
        notifyOnPrintEnd(previous: previousActivity, current: snapshot.activity)
        publishWidgetSnapshot()
    }

    // MARK: - Benachrichtigungen

    /// Meldet das Ende eines Drucks (fertig oder fehlgeschlagen) als Systembenachrichtigung.
    private func notifyOnPrintEnd(previous: PrinterActivity, current: PrinterActivity) {
        guard previous == .printing || previous == .paused, current != previous else { return }
        let title: String
        switch current {
        case .finished: title = "Druck abgeschlossen"
        case .failed: title = "Druck fehlgeschlagen"
        default: return
        }
        let body = snapshot.taskName.isEmpty ? printerName : "\(snapshot.taskName) auf \(printerName)"
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: - Widget

    @ObservationIgnored private var lastWrittenState: (Int, PrinterActivity, Int)?
    @ObservationIgnored private var lastReloadState: (Int, PrinterActivity)?
    @ObservationIgnored private var lastReloadDate: Date = .distantPast

    /// Schreibt den aktuellen Zustand in die App Group, damit das
    /// Desktop-Widget ihn lesen kann.
    ///
    /// Wichtig: WidgetKit budgetiert Timeline-Reloads (grob 40–70 pro Tag).
    /// Ein Reload pro Minute (Restzeit-Änderung) erschöpft das Budget nach
    /// kurzer Zeit und das Widget friert ein. Daher: Daten bei jeder
    /// Änderung schreiben, aber Reloads nur bei Statuswechsel sofort und
    /// bei Fortschritts-Änderungen frühestens alle 3 Minuten anstoßen.
    /// Die Restzeit zählt das Widget selbst live herunter.
    private func publishWidgetSnapshot() {
        let writeState = (snapshot.progressPercent, snapshot.activity, snapshot.remainingMinutes)
        if let last = lastWrittenState, last == writeState { return }
        lastWrittenState = writeState

        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.appGroupID),
              let data = try? JSONEncoder().encode(WidgetSnapshot(from: snapshot, printerName: printerName)) else { return }
        defaults.set(data, forKey: WidgetSnapshot.storageKey)

        let activityChanged = lastReloadState?.1 != snapshot.activity
        let progressChanged = lastReloadState?.0 != snapshot.progressPercent
        let now = Date()
        if activityChanged || (progressChanged && now.timeIntervalSince(lastReloadDate) >= 180) {
            lastReloadState = (snapshot.progressPercent, snapshot.activity)
            lastReloadDate = now
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Führt ein Teil-Update rekursiv in den Gesamtzustand ein.
    private static func deepMerge(_ base: inout [String: Any], _ update: [String: Any]) {
        for (key, value) in update {
            if let updateDict = value as? [String: Any],
               var baseDict = base[key] as? [String: Any] {
                deepMerge(&baseDict, updateDict)
                base[key] = baseDict
            } else {
                base[key] = value
            }
        }
    }

    private static func parseSnapshot(from report: [String: Any]) -> PrinterSnapshot {
        var s = PrinterSnapshot()
        s.taskName = report["subtask_name"] as? String ?? ""
        s.activity = PrinterActivity(rawValue: string(report["gcode_state"]) ?? "") ?? .unknown
        s.progressPercent = int(report["mc_percent"]) ?? 0
        s.remainingMinutes = int(report["mc_remaining_time"]) ?? 0
        s.currentLayer = int(report["layer_num"]) ?? 0
        s.totalLayers = int(report["total_layer_num"]) ?? 0
        s.nozzleTemp = double(report["nozzle_temper"]) ?? 0
        s.nozzleTarget = double(report["nozzle_target_temper"]) ?? 0
        s.bedTemp = double(report["bed_temper"]) ?? 0
        s.bedTarget = double(report["bed_target_temper"]) ?? 0
        s.chamberTemp = double(report["chamber_temper"])

        if let ams = report["ams"] as? [String: Any] {
            s.activeTrayID = string(ams["tray_now"])
            if let units = ams["ams"] as? [[String: Any]] {
                s.amsUnits = units.map { parseAMSUnit($0) }
            }
        }

        if let vt = report["vt_tray"] as? [String: Any] {
            let material = string(vt["tray_type"]) ?? ""
            s.externalSpool = FilamentTray(
                id: "EXT",
                material: material.isEmpty ? "Leer" : material,
                colorHex: string(vt["tray_color"]) ?? "808080FF",
                remainPercent: positivePercent(int(vt["remain"]))
            )
        }
        return s
    }

    private static func parseAMSUnit(_ unit: [String: Any]) -> AMSUnit {
        let unitID = string(unit["id"]) ?? "0"
        let unitIndex = Int(unitID) ?? 0
        let slotLetter = Character(UnicodeScalar(65 + min(unitIndex, 25))!)

        var humidityText: String?
        if let raw = int(unit["humidity_raw"]), raw > 0 {
            humidityText = "\(raw)%"
        } else if let level = int(unit["humidity"]) {
            humidityText = "Stufe \(level)/5"
        }

        var trays: [FilamentTray] = []
        if let trayList = unit["tray"] as? [[String: Any]] {
            for tray in trayList {
                let slotIndex = (int(tray["id"]) ?? 0) + 1
                let material = string(tray["tray_type"]) ?? ""
                trays.append(FilamentTray(
                    id: "\(slotLetter)\(slotIndex)",
                    material: material.isEmpty ? "Leer" : material,
                    colorHex: string(tray["tray_color"]) ?? "808080FF",
                    remainPercent: positivePercent(int(tray["remain"]))
                ))
            }
        }
        return AMSUnit(
            id: unitID,
            humidityText: humidityText,
            temperature: double(unit["temp"]),
            trays: trays
        )
    }

    // Der Drucker liefert Zahlen je nach Firmware mal als String, mal als Zahl.
    private static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func positivePercent(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return min(value, 100)
    }
}
