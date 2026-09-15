//
//  CameraStream.swift
//  BambuMonitor
//
//  Wiederverwendbare Kamera-Stream-Verwaltung für Popover-Karte und
//  Kamera-Fenster. Wählt je nach Druckertyp den passenden Weg:
//  Bambu: RTSP (X1/H2/P2) mit JPEG-Fallback (P1/A1);
//  Snapmaker U1: Snapshot-Polling über Moonraker.
//

import SwiftUI
import Observation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@Observable
@MainActor
final class CameraStreamController {
    private(set) var frame: PlatformImage?
    private(set) var statusText = "Kamera wird verbunden…"

    @ObservationIgnored private var config: PrinterConfig?
    @ObservationIgnored private var accessCode = ""
    @ObservationIgnored private var rtspClient: BambuRTSPCameraClient?
    @ObservationIgnored private var jpegClient: BambuCameraClient?
    @ObservationIgnored private var snapshotClient: HTTPSnapshotCameraClient?
    @ObservationIgnored private var isRunning = false

    func start(config: PrinterConfig, accessCode: String) {
        stop()
        self.config = config
        self.accessCode = accessCode
        isRunning = true
        statusText = "Kamera wird verbunden…"

        switch config.kind {
        case .snapmakerU1:
            startSnapshotStream()
        case .bambu:
            startRTSPStream()
        }
    }

    func stop() {
        isRunning = false
        rtspClient?.stop()
        rtspClient = nil
        jpegClient?.stop()
        jpegClient = nil
        snapshotClient?.stop()
        snapshotClient = nil
        frame = nil
    }

    /// X1-, H2- und P2-Modelle streamen H.264 per RTSPS auf Port 322.
    private func startRTSPStream() {
        guard let config else { return }
        let client = BambuRTSPCameraClient(host: config.host, accessCode: accessCode)
        rtspClient = client
        client.onFrame = { [weak self] image in
            self?.frame = image
        }
        client.onError = { [weak self] _ in
            guard let self else { return }
            self.rtspClient?.stop()
            self.rtspClient = nil
            if self.frame == nil {
                // RTSP nicht verfügbar → JPEG-Protokoll der P1-/A1-Serie versuchen.
                self.startJPEGStream()
            } else {
                self.restartAfterDelay()
            }
        }
        client.start()
    }

    /// P1- und A1-Modelle liefern JPEG-Frames auf Port 6000.
    private func startJPEGStream() {
        guard let config else { return }
        let client = BambuCameraClient(host: config.host, accessCode: accessCode)
        jpegClient = client
        client.onFrame = { [weak self] image in
            self?.frame = image
        }
        client.onError = { [weak self] message in
            guard let self else { return }
            self.jpegClient?.stop()
            self.jpegClient = nil
            if self.frame == nil {
                self.statusText = "\(message)\nAm Drucker muss „LAN-Liveview“ aktiviert sein."
            } else {
                self.restartAfterDelay()
            }
        }
        client.start()
    }

    /// Snapmaker U1: JPEG-Snapshots über die Moonraker-Webcam-API.
    private func startSnapshotStream() {
        guard let config else { return }
        let client = HTTPSnapshotCameraClient(host: config.host)
        snapshotClient = client
        client.onFrame = { [weak self] image in
            self?.frame = image
        }
        client.onError = { [weak self] message in
            guard let self, self.frame == nil else { return }
            self.statusText = message
        }
        client.start()
    }

    /// Verbindung mitten im Stream verloren → kurz warten und neu aufbauen.
    private func restartAfterDelay() {
        frame = nil
        statusText = "Verbindung verloren – neuer Versuch…"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.isRunning,
                  self.rtspClient == nil, self.jpegClient == nil, self.snapshotClient == nil,
                  let config = self.config else { return }
            self.start(config: config, accessCode: self.accessCode)
        }
    }
}

// MARK: - Kamera-Fenster

/// Eigenständiges Fenster mit dem Livestream in groß – wird per Klick auf
/// das Kamerabild im Popover geöffnet und streamt unabhängig davon weiter.
struct CameraWindowView: View {
    var monitor: PrinterMonitor
    @State private var stream = CameraStreamController()

    var body: some View {
        ZStack {
            Color.black
            if let frame = stream.frame {
                Image(platformImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
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
        }
        .frame(minWidth: 480, minHeight: 300)
        .navigationTitle(monitor.activeConfig.map { "Kamera – \($0.name)" } ?? "Kamera")
        .onAppear(perform: startStream)
        .onDisappear(perform: stream.stop)
        // Bei Druckerwechsel den Stream auf den neuen Drucker umstellen.
        .onChange(of: monitor.activePrinterID) {
            startStream()
        }
    }

    private func startStream() {
        if let config = monitor.activeConfig, monitor.isConfigured {
            stream.start(config: config, accessCode: monitor.activeAccessCode)
        } else {
            stream.stop()
        }
    }
}
