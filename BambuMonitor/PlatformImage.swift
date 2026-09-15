//
//  PlatformImage.swift
//  BambuMonitor
//
//  Plattform-Abstraktion für Bilder, damit die Kamera-Clients und
//  Stream-Logik auf macOS (NSImage) und iOS (UIImage) identisch
//  kompilieren.
//

import SwiftUI
import CoreGraphics

#if canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    static func fromCGImage(_ cgImage: CGImage) -> PlatformImage {
        #if canImport(AppKit)
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        UIImage(cgImage: cgImage)
        #endif
    }
}
