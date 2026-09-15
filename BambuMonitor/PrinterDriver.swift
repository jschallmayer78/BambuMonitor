//
//  PrinterDriver.swift
//  BambuMonitor
//
//  Abstraktion über die herstellerspezifischen Drucker-Protokolle.
//  BambuDriver: lokales MQTT (Port 8883), Reports als JSON-Diffs.
//  SnapmakerU1Driver (eigene Datei): Moonraker-HTTP-Polling.
//

import Foundation

@MainActor
protocol PrinterDriver: AnyObject {
    var onSnapshot: ((PrinterSnapshot) -> Void)? { get set }
    var onStatus: ((ConnectionStatus) -> Void)? { get set }
    func connect()
    func disconnect()
    func refresh()
}

// MARK: - Bambu Lab (MQTT)

@MainActor
final class BambuDriver: PrinterDriver {
    var onSnapshot: ((PrinterSnapshot) -> Void)?
    var onStatus: ((ConnectionStatus) -> Void)?

    private let host: String
    private let serial: String
    private let accessCode: String
    private var client: BambuMQTTClient?
    /// Bambu sendet nach dem ersten "pushall" nur noch Teil-Updates –
    /// hier wird der zusammengeführte Gesamtzustand gehalten.
    private var mergedReport: [String: Any] = [:]

    init(host: String, serial: String, accessCode: String) {
        self.host = host
        self.serial = serial
        self.accessCode = accessCode
    }

    func connect() {
        disconnect()
        mergedReport = [:]

        let client = BambuMQTTClient(host: host, accessCode: accessCode, serial: serial)
        self.client = client
        client.onStateChange = { [weak self, weak client] state in
            guard let self, let client, self.client === client else { return }
            switch state {
            case .connecting: self.onStatus?(.connecting)
            case .connected: self.onStatus?(.connected)
            case .disconnected(let reason): self.onStatus?(.disconnected(reason))
            }
        }
        client.onMessage = { [weak self, weak client] _, payload in
            guard let self, let client, self.client === client else { return }
            self.handleReport(payload)
        }
        client.connect()
    }

    func disconnect() {
        client?.onStateChange = nil
        client?.onMessage = nil
        client?.disconnect(notify: false)
        client = nil
    }

    func refresh() {
        client?.requestFullStatus()
    }

    private func handleReport(_ payload: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let printUpdate = json["print"] as? [String: Any] else { return }

        var merged = mergedReport
        Self.deepMerge(&merged, printUpdate)
        mergedReport = merged
        onSnapshot?(Self.parseSnapshot(from: merged))
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

    // MARK: - Report-Parsing

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
            // tray_now ist ein globaler Slot-Index über alle AMS-Module
            // (0–3 = AMS A usw., 254 = externe Spule, 255 = keiner).
            if let trayNow = int(string(ams["tray_now"]) ?? "") {
                if trayNow == 254 {
                    s.activeTrayID = "EXT"
                } else if trayNow >= 0 && trayNow < 128 {
                    let letter = Character(UnicodeScalar(65 + min(trayNow / 4, 25))!)
                    s.activeTrayID = "\(letter)\(trayNow % 4 + 1)"
                }
            }
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
