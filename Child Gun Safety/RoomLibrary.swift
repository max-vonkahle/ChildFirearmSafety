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
    
    static func delete(_ roomId: String) {
        let id = roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let candidates = [
            docs.appendingPathComponent("room_\(id)").appendingPathExtension("arworldmap"),
            docs.appendingPathComponent(id).appendingPathExtension("arworldmap")
        ]
        for url in candidates {
            if fm.fileExists(atPath: url.path) {
                do {
                    try fm.removeItem(at: url)
                    #if DEBUG
                    print("[RoomLibrary] deleted \(id) -> \(url.lastPathComponent)")
                    #endif
                    return
                } catch {
                    #if DEBUG
                    print("[RoomLibrary] delete failed \(id): \(error.localizedDescription)")
                    #endif
                }
            }
        }
        if let urls = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            for u in urls where u.pathExtension.lowercased() == "arworldmap" {
                var base = u.deletingPathExtension().lastPathComponent
                if base.hasPrefix("room_") { base.removeFirst("room_".count) }
                if base == id {
                    try? fm.removeItem(at: u)
                    #if DEBUG
                    print("[RoomLibrary] deleted \(id) (fallback) -> \(u.lastPathComponent)")
                    #endif
                    break
                }
            }
        }
    }
}
