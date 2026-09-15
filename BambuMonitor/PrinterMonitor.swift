//
//  PrinterMonitor.swift
//  BambuMonitor
//
//  Orchestriert die konfigurierten Drucker: hält für JEDEN vollständig
//  konfigurierten Drucker einen laufenden Treiber (damit Widgets und
//  Benachrichtigungen alle Drucker abdecken), zeigt in der UI den
//  aktiven Drucker und schreibt pro Drucker Widget-Daten in die App Group.
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

    // MARK: - Drucker-Liste (persistiert in UserDefaults)

    private(set) var printers: [PrinterConfig] {
        didSet {
            persistPrinters()
            publishPrinterDirectory()
        }
    }
    private(set) var activePrinterID: UUID? {
        didSet {
            UserDefaults.standard.set(activePrinterID?.uuidString, forKey: "activePrinterID")
            publishPrinterDirectory()
        }
    }

    /// Access Code des aktiven Druckers (nur Bambu; liegt im Keychain).
    var activeAccessCode: String = "" {
        didSet {
            guard !suppressAccessCodeSave, let id = activePrinterID else { return }
            KeychainHelper.saveAccessCode(activeAccessCode, for: id)
        }
    }
    @ObservationIgnored private var suppressAccessCodeSave = false

    var activeConfig: PrinterConfig? {
        printers.first { $0.id == activePrinterID }
    }

    var isConfigured: Bool {
        guard let config = activeConfig, config.isComplete else { return false }
        if config.kind == .bambu { return !activeAccessCode.isEmpty }
        return true
    }

    /// Solange kein Drucker konfiguriert ist, zeigt die UI Beispieldaten.
    var isDemoMode: Bool { printers.isEmpty }

    // MARK: - Zustand pro Drucker

    private(set) var snapshots: [UUID: PrinterSnapshot] = [:]
    private(set) var statuses: [UUID: ConnectionStatus] = [:]
    private(set) var lastUpdates: [UUID: Date] = [:]

    /// Zustand des aktiven Druckers – Schnittstelle für die UI.
    var snapshot: PrinterSnapshot {
        if let id = activePrinterID, let s = snapshots[id] { return s }
        return isDemoMode ? .demo : PrinterSnapshot()
    }

    var status: ConnectionStatus {
        guard let id = activePrinterID else { return .notConfigured }
        return statuses[id] ?? .notConfigured
    }

    var lastUpdate: Date? {
        activePrinterID.flatMap { lastUpdates[$0] }
    }

    @ObservationIgnored private var drivers: [UUID: PrinterDriver] = [:]
    @ObservationIgnored private var reconnectTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Initialisierung

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "printerConfigs"),
           let configs = try? JSONDecoder().decode([PrinterConfig].self, from: data) {
            printers = configs
        } else {
            printers = []
        }
        if let idString = defaults.string(forKey: "activePrinterID"),
           let id = UUID(uuidString: idString) {
            activePrinterID = id
        }

        migrateLegacySinglePrinter()

        if activePrinterID == nil || activeConfig == nil {
            activePrinterID = printers.first?.id
        }
        loadActiveAccessCode()
        publishPrinterDirectory()
        connect()
    }

    /// Übernimmt die Einzeldrucker-Konfiguration aus Versionen vor der
    /// Multi-Drucker-Unterstützung (printerHost/printerSerial/printerName).
    private func migrateLegacySinglePrinter() {
        let defaults = UserDefaults.standard
        guard printers.isEmpty,
              let host = defaults.string(forKey: "printerHost"), !host.isEmpty else { return }

        var config = PrinterConfig(kind: .bambu, name: defaults.string(forKey: "printerName") ?? "Bambu Drucker")
        config.host = host
        config.serial = defaults.string(forKey: "printerSerial") ?? ""
        printers = [config]
        activePrinterID = config.id

        if let legacyCode = KeychainHelper.legacyAccessCode(), !legacyCode.isEmpty {
            KeychainHelper.saveAccessCode(legacyCode, for: config.id)
            KeychainHelper.deleteLegacyAccessCode()
        }
        for key in ["printerHost", "printerSerial", "printerName"] {
            defaults.removeObject(forKey: key)
        }
    }

    private func persistPrinters() {
        if let data = try? JSONEncoder().encode(printers) {
            UserDefaults.standard.set(data, forKey: "printerConfigs")
        }
    }

    private func loadActiveAccessCode() {
        suppressAccessCodeSave = true
        if let id = activePrinterID {
            activeAccessCode = KeychainHelper.loadAccessCode(for: id) ?? ""
        } else {
            activeAccessCode = ""
        }
        suppressAccessCodeSave = false
    }

    // MARK: - Drucker verwalten

    func selectPrinter(_ id: UUID) {
        guard id != activePrinterID, printers.contains(where: { $0.id == id }) else { return }
        // Die Treiber laufen für alle Drucker weiter – nur die Anzeige wechselt.
        activePrinterID = id
        loadActiveAccessCode()
    }

    func addPrinter(kind: PrinterKind) {
        let config = PrinterConfig(kind: kind, name: kind.defaultPrinterName)
        printers.append(config)
        activePrinterID = config.id
        loadActiveAccessCode()
    }

    func removeActivePrinter() {
        guard let id = activePrinterID else { return }
        stopDriver(for: id)
        KeychainHelper.deleteAccessCode(for: id)
        printers.removeAll { $0.id == id }
        snapshots[id] = nil
        statuses[id] = nil
        lastUpdates[id] = nil
        removeWidgetData(for: id)
        activePrinterID = printers.first?.id
        loadActiveAccessCode()
    }

    /// Ändert Felder der aktiven Konfiguration (für UI-Bindings).
    func updateActiveConfig(_ transform: (inout PrinterConfig) -> Void) {
        guard let index = printers.firstIndex(where: { $0.id == activePrinterID }) else { return }
        transform(&printers[index])
    }

    // MARK: - Verbindungen

    /// Baut die Treiber für ALLE vollständig konfigurierten Drucker (neu) auf.
    func connect() {
        disconnect()
        for config in printers where config.isComplete {
            startDriver(for: config)
        }
    }

    func disconnect() {
        for id in drivers.keys {
            reconnectTasks[id]?.cancel()
        }
        reconnectTasks.removeAll()
        for (_, driver) in drivers {
            driver.onSnapshot = nil
            driver.onStatus = nil
            driver.disconnect()
        }
        drivers.removeAll()
    }

    func refresh() {
        if let id = activePrinterID, let driver = drivers[id] {
            driver.refresh()
        } else {
            connect()
        }
    }

    private func startDriver(for config: PrinterConfig) {
        stopDriver(for: config.id)

        let driver: PrinterDriver
        switch config.kind {
        case .bambu:
            let accessCode = KeychainHelper.loadAccessCode(for: config.id) ?? ""
            guard !accessCode.isEmpty else {
                statuses[config.id] = .notConfigured
                return
            }
            driver = BambuDriver(host: config.host, serial: config.serial, accessCode: accessCode)
        case .snapmakerU1:
            driver = SnapmakerU1Driver(host: config.host)
        }
        drivers[config.id] = driver
        let printerID = config.id

        driver.onStatus = { [weak self, weak driver] newStatus in
            guard let self, let driver, self.drivers[printerID] === driver else { return }
            self.statuses[printerID] = newStatus
            if case .disconnected = newStatus, config.kind == .bambu {
                self.scheduleReconnect(for: config)
            }
        }
        driver.onSnapshot = { [weak self, weak driver] newSnapshot in
            guard let self, let driver, self.drivers[printerID] === driver else { return }
            let previous = self.snapshots[printerID]?.activity ?? .unknown
            self.snapshots[printerID] = newSnapshot
            self.lastUpdates[printerID] = Date()
            self.notifyOnPrintEnd(previous: previous, current: newSnapshot, printerName: config.name)
            self.publishWidgetSnapshot(for: printerID, printerName: config.name)
        }
        driver.connect()
    }

    private func stopDriver(for id: UUID) {
        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = nil
        if let driver = drivers[id] {
            driver.onSnapshot = nil
            driver.onStatus = nil
            driver.disconnect()
            drivers[id] = nil
        }
    }

    /// Der U1-Treiber pollt selbstständig weiter; nur verbindungsorientierte
    /// Treiber (Bambu-MQTT) brauchen einen Neuaufbau.
    private func scheduleReconnect(for config: PrinterConfig) {
        reconnectTasks[config.id]?.cancel()
        reconnectTasks[config.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.startDriver(for: config)
        }
    }

    // MARK: - Benachrichtigungen

    /// Meldet das Ende eines Drucks (fertig oder fehlgeschlagen) als Systembenachrichtigung.
    private func notifyOnPrintEnd(previous: PrinterActivity, current: PrinterSnapshot, printerName: String) {
        guard previous == .printing || previous == .paused, current.activity != previous else { return }
        let title: String
        switch current.activity {
        case .finished: title = "Druck abgeschlossen"
        case .failed: title = "Druck fehlgeschlagen"
        default: return
        }
        let body = current.taskName.isEmpty ? printerName : "\(current.taskName) auf \(printerName)"
        Self.postNotification(title: title, body: body)
    }

    static func postNotification(title: String, body: String) {
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

    // MARK: - Widgets

    @ObservationIgnored private var lastWrittenStates: [UUID: (Int, PrinterActivity, Int)] = [:]
    @ObservationIgnored private var lastReloadStates: [UUID: (Int, PrinterActivity)] = [:]
    @ObservationIgnored private var lastReloadDate: Date = .distantPast

    /// Liste aller Drucker plus aktiver Drucker – Basis für die
    /// Drucker-Auswahl in der Widget-Konfiguration.
    private func publishPrinterDirectory() {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.appGroupID) else { return }
        let list = printers.map { WidgetPrinterInfo(id: $0.id.uuidString, name: $0.name) }
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: WidgetSnapshot.printerListKey)
        }
        defaults.set(activePrinterID?.uuidString, forKey: WidgetSnapshot.activePrinterKey)
    }

    private func removeWidgetData(for id: UUID) {
        UserDefaults(suiteName: WidgetSnapshot.appGroupID)?
            .removeObject(forKey: WidgetSnapshot.storageKey(for: id.uuidString))
    }

    /// Schreibt den Zustand eines Druckers in die App Group.
    ///
    /// Wichtig: WidgetKit budgetiert Timeline-Reloads (grob 40–70 pro Tag).
    /// Daher: Daten bei jeder Änderung schreiben, aber Reloads nur bei
    /// Statuswechsel sofort und bei Fortschritts-Änderungen frühestens
    /// alle 3 Minuten anstoßen. Die Restzeit zählt das Widget selbst
    /// live herunter.
    private func publishWidgetSnapshot(for id: UUID, printerName: String) {
        guard let current = snapshots[id] else { return }
        let writeState = (current.progressPercent, current.activity, current.remainingMinutes)
        if let last = lastWrittenStates[id], last == writeState { return }
        lastWrittenStates[id] = writeState

        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.appGroupID),
              let data = try? JSONEncoder().encode(WidgetSnapshot(from: current, printerName: printerName)) else { return }
        defaults.set(data, forKey: WidgetSnapshot.storageKey(for: id.uuidString))

        let activityChanged = lastReloadStates[id]?.1 != current.activity
        let progressChanged = lastReloadStates[id]?.0 != current.progressPercent
        let now = Date()
        if activityChanged || (progressChanged && now.timeIntervalSince(lastReloadDate) >= 180) {
            lastReloadStates[id] = (current.progressPercent, current.activity)
            lastReloadDate = now
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
