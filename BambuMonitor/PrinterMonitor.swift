//
//  PrinterMonitor.swift
//  BambuMonitor
//
//  Orchestriert die konfigurierten Drucker: verwaltet die Drucker-Liste,
//  den aktiven Drucker und dessen Treiber, und übersetzt Snapshot-Updates
//  in UI-Zustand, Benachrichtigungen und Widget-Daten.
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
        didSet { persistPrinters() }
    }
    private(set) var activePrinterID: UUID? {
        didSet { UserDefaults.standard.set(activePrinterID?.uuidString, forKey: "activePrinterID") }
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

    // MARK: - Zustand des aktiven Druckers

    private(set) var snapshot = PrinterSnapshot()
    private(set) var status: ConnectionStatus = .notConfigured
    private(set) var lastUpdate: Date?

    @ObservationIgnored private var driver: PrinterDriver?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

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

        if isConfigured {
            connect()
        } else if isDemoMode {
            snapshot = .demo
        }
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
        disconnect()
        activePrinterID = id
        loadActiveAccessCode()
        snapshot = PrinterSnapshot()
        connect()
    }

    func addPrinter(kind: PrinterKind) {
        let config = PrinterConfig(kind: kind, name: kind.defaultPrinterName)
        printers.append(config)
        disconnect()
        activePrinterID = config.id
        loadActiveAccessCode()
        snapshot = PrinterSnapshot()
        status = .notConfigured
    }

    func removeActivePrinter() {
        guard let id = activePrinterID else { return }
        disconnect()
        KeychainHelper.deleteAccessCode(for: id)
        printers.removeAll { $0.id == id }
        activePrinterID = printers.first?.id
        loadActiveAccessCode()
        snapshot = isDemoMode ? .demo : PrinterSnapshot()
        status = .notConfigured
        if isConfigured { connect() }
    }

    /// Ändert Felder der aktiven Konfiguration (für UI-Bindings).
    func updateActiveConfig(_ transform: (inout PrinterConfig) -> Void) {
        guard let index = printers.firstIndex(where: { $0.id == activePrinterID }) else { return }
        transform(&printers[index])
    }

    // MARK: - Verbindung

    func connect() {
        guard let config = activeConfig, isConfigured else {
            status = .notConfigured
            if isDemoMode { snapshot = .demo }
            return
        }
        reconnectTask?.cancel()
        driver?.onSnapshot = nil
        driver?.onStatus = nil
        driver?.disconnect()
        snapshot = PrinterSnapshot()

        let driver: PrinterDriver
        switch config.kind {
        case .bambu:
            driver = BambuDriver(host: config.host, serial: config.serial, accessCode: activeAccessCode)
        case .snapmakerU1:
            driver = SnapmakerU1Driver(host: config.host)
        }
        self.driver = driver

        driver.onStatus = { [weak self, weak driver] newStatus in
            guard let self, let driver, self.driver === driver else { return }
            self.status = newStatus
            if case .disconnected = newStatus {
                self.scheduleReconnectIfNeeded()
            }
        }
        driver.onSnapshot = { [weak self, weak driver] newSnapshot in
            guard let self, let driver, self.driver === driver else { return }
            self.lastUpdate = Date()
            let previousActivity = self.snapshot.activity
            self.snapshot = newSnapshot
            self.notifyOnPrintEnd(previous: previousActivity, current: newSnapshot.activity)
            self.publishWidgetSnapshot()
        }
        driver.connect()
    }

    func disconnect() {
        reconnectTask?.cancel()
        driver?.onSnapshot = nil
        driver?.onStatus = nil
        driver?.disconnect()
        driver = nil
        status = isConfigured ? .disconnected(nil) : .notConfigured
    }

    func refresh() {
        if status == .connected {
            driver?.refresh()
        } else {
            connect()
        }
    }

    /// Der U1-Treiber pollt selbstständig weiter; nur verbindungsorientierte
    /// Treiber (Bambu-MQTT) brauchen einen Neuaufbau.
    private func scheduleReconnectIfNeeded() {
        guard activeConfig?.kind == .bambu else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
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
        let printerName = activeConfig?.name ?? "Drucker"
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
              let data = try? JSONEncoder().encode(WidgetSnapshot(from: snapshot, printerName: activeConfig?.name ?? "Drucker")) else { return }
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
}
