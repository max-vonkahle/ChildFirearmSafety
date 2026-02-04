//
//  WorldMapStore.swift
//  Child Firearm Safety
//
//  Created by Max on 9/25/25.
//


// WorldMapStore.swift
import Foundation
import ARKit

enum WorldMapStore {
    static func url(for roomId: String) -> URL {
        let fn = "room_\(roomId).arworldmap"
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(fn)
    }

    static func save(_ map: ARWorldMap, roomId: String) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
        try data.write(to: url(for: roomId), options: [.atomic])
    }

    static func load(roomId: String) throws -> ARWorldMap {
        let data = try Data(contentsOf: url(for: roomId))
        guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
            throw NSError(domain: "WorldMapStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to decode ARWorldMap"])
        }
        return map
    }

    static func exists(roomId: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: roomId).path)
    }
}
