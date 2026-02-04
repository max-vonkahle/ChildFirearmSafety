//
//  RoomLibrary.swift
//  Child Firearm Safety
//
//  Centralized helpers for listing saved AR rooms.
//

import Foundation
import simd
import ARKit

enum RoomLibrary {
    // MARK: - Training Rooms (ARWorldMap)

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

    // MARK: - Testing Rooms (Back Wall Transform)

    struct TestingRoomData: Codable {
        let backWallTransform: [Float]  // 16 floats for 4x4 matrix
        let wallNormal: [Float]?  // 4 floats for wall normal (optional for backwards compatibility)
        let assetTransforms: [String: [Float]]?  // Asset name -> transform matrix (optional)
        let createdAt: Date

        init(transform: simd_float4x4, wallNormal: SIMD4<Float>? = nil, assets: [String: simd_float4x4]? = nil) {
            // Flatten matrix to array
            self.backWallTransform = [
                transform.columns.0.x, transform.columns.0.y, transform.columns.0.z, transform.columns.0.w,
                transform.columns.1.x, transform.columns.1.y, transform.columns.1.z, transform.columns.1.w,
                transform.columns.2.x, transform.columns.2.y, transform.columns.2.z, transform.columns.2.w,
                transform.columns.3.x, transform.columns.3.y, transform.columns.3.z, transform.columns.3.w
            ]
            if let normal = wallNormal {
                self.wallNormal = [normal.x, normal.y, normal.z, normal.w]
            } else {
                self.wallNormal = nil
            }
            if let assets = assets {
                var flattened: [String: [Float]] = [:]
                for (name, transform) in assets {
                    flattened[name] = [
                        transform.columns.0.x, transform.columns.0.y, transform.columns.0.z, transform.columns.0.w,
                        transform.columns.1.x, transform.columns.1.y, transform.columns.1.z, transform.columns.1.w,
                        transform.columns.2.x, transform.columns.2.y, transform.columns.2.z, transform.columns.2.w,
                        transform.columns.3.x, transform.columns.3.y, transform.columns.3.z, transform.columns.3.w
                    ]
                }
                self.assetTransforms = flattened
            } else {
                self.assetTransforms = nil
            }
            self.createdAt = Date()
        }

        func getTransform() -> simd_float4x4 {
            let m = backWallTransform
            return simd_float4x4(
                SIMD4<Float>(m[0], m[1], m[2], m[3]),
                SIMD4<Float>(m[4], m[5], m[6], m[7]),
                SIMD4<Float>(m[8], m[9], m[10], m[11]),
                SIMD4<Float>(m[12], m[13], m[14], m[15])
            )
        }

        func getWallNormal() -> SIMD4<Float>? {
            guard let n = wallNormal else { return nil }
            return SIMD4<Float>(n[0], n[1], n[2], n[3])
        }

        func getAssetTransforms() -> [String: simd_float4x4] {
            guard let assetTransforms = assetTransforms else { return [:] }
            var result: [String: simd_float4x4] = [:]
            for (name, m) in assetTransforms {
                result[name] = simd_float4x4(
                    SIMD4<Float>(m[0], m[1], m[2], m[3]),
                    SIMD4<Float>(m[4], m[5], m[6], m[7]),
                    SIMD4<Float>(m[8], m[9], m[10], m[11]),
                    SIMD4<Float>(m[12], m[13], m[14], m[15])
                )
            }
            return result
        }
    }

    static func savedTestingRooms() -> [String] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        guard let urls = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) else {
            return []
        }
        let names: [String] = urls.compactMap { url in
            // Look for .arworldmap files (new format) or .testroom files (legacy)
            guard url.pathExtension.lowercased() == "arworldmap" || url.pathExtension.lowercased() == "testroom" else { return nil }
            var base = url.deletingPathExtension().lastPathComponent
            if base.hasPrefix("testing_") { base.removeFirst("testing_".count) }
            return base
        }
        return Array(Set(names)).sorted() // Remove duplicates and sort
    }

    static func saveTestingRoom(roomId: String, worldMap: ARWorldMap, assets: [String: simd_float4x4]) {
        let id = roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }

        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!

        // Save ARWorldMap (like training rooms)
        let worldMapURL = docs.appendingPathComponent("testing_\(id)").appendingPathExtension("arworldmap")

        // Save asset transforms separately
        let assetsURL = docs.appendingPathComponent("testing_\(id)_assets").appendingPathExtension("json")

        do {
            // Save world map
            let worldMapData = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
            try worldMapData.write(to: worldMapURL)

            // Save asset transforms
            let testingData = TestingRoomData(transform: matrix_identity_float4x4, wallNormal: nil, assets: assets)
            let assetsData = try JSONEncoder().encode(testingData)
            try assetsData.write(to: assetsURL)

            print("[RoomLibrary] ✅ Saved testing room '\(id)' with ARWorldMap and \(assets.count) assets")
        } catch {
            print("[RoomLibrary] ❌ Failed to save testing room '\(id)': \(error.localizedDescription)")
        }
    }

    static func loadTestingRoom(roomId: String) -> (worldMap: ARWorldMap, assets: [String: simd_float4x4])? {
        let id = roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            print("[RoomLibrary] ❌ Empty roomId provided")
            return nil
        }

        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let worldMapURL = docs.appendingPathComponent("testing_\(id)").appendingPathExtension("arworldmap")
        let assetsURL = docs.appendingPathComponent("testing_\(id)_assets").appendingPathExtension("json")

        print("[RoomLibrary] 🔍 Looking for ARWorldMap at: \(worldMapURL.path)")
        print("[RoomLibrary] 🔍 Looking for assets at: \(assetsURL.path)")

        guard fm.fileExists(atPath: worldMapURL.path) else {
            print("[RoomLibrary] ❌ Testing room ARWorldMap '\(id)' not found")
            return nil
        }

        do {
            // Load ARWorldMap
            let worldMapData = try Data(contentsOf: worldMapURL)
            guard let worldMap = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: worldMapData) else {
                print("[RoomLibrary] ❌ Failed to unarchive ARWorldMap")
                return nil
            }

            // Load asset transforms
            var assets: [String: simd_float4x4] = [:]
            if fm.fileExists(atPath: assetsURL.path) {
                let assetsData = try Data(contentsOf: assetsURL)
                let decoded = try JSONDecoder().decode(TestingRoomData.self, from: assetsData)
                assets = decoded.getAssetTransforms()
            }

            print("[RoomLibrary] ✅ Loaded testing room '\(id)' with ARWorldMap and \(assets.count) assets")
            print("[RoomLibrary] 📋 Asset keys: \(assets.keys.sorted())")
            return (worldMap, assets)
        } catch {
            print("[RoomLibrary] ❌ Failed to load testing room '\(id)': \(error.localizedDescription)")
            return nil
        }
    }

    static func deleteTestingRoom(_ roomId: String) {
        let id = roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }

        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!

        // Delete new format files (.arworldmap + _assets.json)
        let worldMapURL = docs.appendingPathComponent("testing_\(id)").appendingPathExtension("arworldmap")
        let assetsURL = docs.appendingPathComponent("testing_\(id)_assets").appendingPathExtension("json")

        var deletedCount = 0

        if fm.fileExists(atPath: worldMapURL.path) {
            do {
                try fm.removeItem(at: worldMapURL)
                deletedCount += 1
                print("[RoomLibrary] 🗑️ Deleted world map: \(worldMapURL.lastPathComponent)")
            } catch {
                print("[RoomLibrary] ❌ Failed to delete world map '\(id)': \(error.localizedDescription)")
            }
        }

        if fm.fileExists(atPath: assetsURL.path) {
            do {
                try fm.removeItem(at: assetsURL)
                deletedCount += 1
                print("[RoomLibrary] 🗑️ Deleted assets: \(assetsURL.lastPathComponent)")
            } catch {
                print("[RoomLibrary] ❌ Failed to delete assets '\(id)': \(error.localizedDescription)")
            }
        }

        // Also try to delete old format file (.testroom) for backwards compatibility
        let oldFileURL = docs.appendingPathComponent("testing_\(id)").appendingPathExtension("testroom")
        if fm.fileExists(atPath: oldFileURL.path) {
            do {
                try fm.removeItem(at: oldFileURL)
                deletedCount += 1
                print("[RoomLibrary] 🗑️ Deleted old format: \(oldFileURL.lastPathComponent)")
            } catch {
                print("[RoomLibrary] ❌ Failed to delete old format '\(id)': \(error.localizedDescription)")
            }
        }

        if deletedCount > 0 {
            print("[RoomLibrary] ✅ Deleted testing room '\(id)' (\(deletedCount) files)")
        } else {
            print("[RoomLibrary] ⚠️ No files found to delete for '\(id)'")
        }
    }
}
