//
//  Item.swift
//  BambuMonitor
//
//  Created by Jörg Schallmayer on 11.09.26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
