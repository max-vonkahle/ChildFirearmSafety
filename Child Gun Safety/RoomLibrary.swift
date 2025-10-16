//
//  RoomLibrary.swift
//  Child Gun Safety
//
//  Centralized helpers for listing saved AR rooms.
//

import Foundation

enum RoomLibrary {
    static func savedRooms() -> [String] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        guard let urls = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) else {
            return []
        }
        let names: [String] = urls.compactMap { url in
            guard url.pathExtension.lowercased() == "arworldmap" else { return nil }
            var base = url.deletingPathExtension().lastPathComponent
            if base.hasPrefix("room_") { base.removeFirst("room_".count) }
            return base
        }
        return names.sorted()
    }
}
