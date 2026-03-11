//
//  RoomLibrary.swift
//  Child Firearm Safety
//
//  Centralized helpers for listing saved AR rooms.
//

import Foundation
import simd
import ARKit

enum TestingStage: String, CaseIterable, Codable {
    case kitchen
    case garage
    case bedroom

    var assetName: String { rawValue }
    var displayName: String { rawValue.capitalized }

    var scenarioSetupText: String {
        switch self {
        case .kitchen:
            return "The child is at their friend's house and was asked to go to the kitchen to find cookies for a snack."
        case .garage:
            return "The child is at their friend's house and was asked to go to the garage to find a toy."
        case .bedroom:
            return "The child is playing hide and seek and decides to hide in the bedroom next to the bed."
        }
    }

    var startPromptText: String {
        switch self {
        case .kitchen:
            return "You're in your friend's kitchen. They asked you to find the cookies for a snack. Look around - what do you see?"
        case .garage:
            return "You're in your friend's garage. They asked you to find a toy. Look around - what do you see?"
        case .bedroom:
            return "You're playing hide and seek, and you decide to hide in the bedroom next to the bed. Look around - what do you see?"
        }
    }

    var gunRelativeOffset: SIMD3<Float> {
        switch self {
        case .kitchen:
            return SIMD3<Float>(0.5823, 0.8431, -2.5297)
        case .garage:
            return SIMD3<Float>(-2.39, 0.360, -0.304)
        case .bedroom:
            return SIMD3<Float>(2.657, 0.790, -0.914)
        }
    }

    /// Additional yaw rotation (radians) applied to the gun around the world Y axis.
    var gunYawOffset: Float {
        switch self {
        case .kitchen: return 0
        case .garage:  return 0
        case .bedroom: return .pi / 2
        }
    }

    var gunAssetKey: String { "gun_\(rawValue)" }
}

struct StartPositionAlignmentStatus: Equatable {
    var horizontalDistanceMeters: Float
    var yawDeltaDegrees: Float

    static let distanceTolerance: Float = 0.35
    static let yawToleranceDegrees: Float = 20

    var isAligned: Bool {
        horizontalDistanceMeters <= Self.distanceTolerance &&
        yawDeltaDegrees <= Self.yawToleranceDegrees
    }

    var guidanceText: String {
        if isAligned { return "Aligned - tap to continue" }
        if horizontalDistanceMeters > Self.distanceTolerance { return "Move closer to the start position" }
        return "Turn to match the start direction"
    }
}

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

            // Only return training rooms (those starting with "room_")
            guard base.hasPrefix("room_") else { return nil }
            base.removeFirst("room_".count)
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
                    // print("[RoomLibrary] deleted \(id) -> \(url.lastPathComponent)")
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
                    // print("[RoomLibrary] deleted \(id) (fallback) -> \(u.lastPathComponent)")
                    #endif
                    break
                }
            }
        }
    }

    // MARK: - Testing Rooms (Back Wall Transform)

    struct TestingRoomData: Codable {
        let schemaVersion: Int?
        let backWallTransform: [Float]  // 16 floats for 4x4 matrix
        let wallNormal: [Float]?  // 4 floats for wall normal (optional for backwards compatibility)
        let assetTransforms: [String: [Float]]?  // Asset name -> transform matrix (optional)
        let startCameraTransform: [Float]?  // Saved device pose for stage reset alignment
        let createdAt: Date

        init(
            transform: simd_float4x4,
            wallNormal: SIMD4<Float>? = nil,
            assets: [String: simd_float4x4]? = nil,
            startCameraTransform: simd_float4x4? = nil
        ) {
            self.schemaVersion = 2
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
            if let startCameraTransform {
                self.startCameraTransform = [
                    startCameraTransform.columns.0.x, startCameraTransform.columns.0.y, startCameraTransform.columns.0.z, startCameraTransform.columns.0.w,
                    startCameraTransform.columns.1.x, startCameraTransform.columns.1.y, startCameraTransform.columns.1.z, startCameraTransform.columns.1.w,
                    startCameraTransform.columns.2.x, startCameraTransform.columns.2.y, startCameraTransform.columns.2.z, startCameraTransform.columns.2.w,
                    startCameraTransform.columns.3.x, startCameraTransform.columns.3.y, startCameraTransform.columns.3.z, startCameraTransform.columns.3.w
                ]
            } else {
                self.startCameraTransform = nil
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

        func getStartCameraTransform() -> simd_float4x4? {
            guard let m = startCameraTransform, m.count == 16 else { return nil }
            return simd_float4x4(
                SIMD4<Float>(m[0], m[1], m[2], m[3]),
                SIMD4<Float>(m[4], m[5], m[6], m[7]),
                SIMD4<Float>(m[8], m[9], m[10], m[11]),
                SIMD4<Float>(m[12], m[13], m[14], m[15])
            )
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

            // Only return testing rooms (those starting with "testing_")
            guard base.hasPrefix("testing_") else { return nil }
            base.removeFirst("testing_".count)
            return base
        }
        return Array(Set(names)).sorted() // Remove duplicates and sort
    }

    static func saveTestingRoom(
        roomId: String,
        worldMap: ARWorldMap,
        assets: [String: simd_float4x4],
        startCameraTransform: simd_float4x4? = nil
    ) {
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
            let testingData = TestingRoomData(
                transform: matrix_identity_float4x4,
                wallNormal: nil,
                assets: assets,
                startCameraTransform: startCameraTransform
            )
            let assetsData = try JSONEncoder().encode(testingData)
            try assetsData.write(to: assetsURL)

            // print("[RoomLibrary] ✅ Saved testing room '\(id)' with ARWorldMap and \(assets.count) assets")
        } catch {
            print("[RoomLibrary] ❌ Failed to save testing room '\(id)': \(error.localizedDescription)")
        }
    }

    static func loadTestingRoom(roomId: String) -> (worldMap: ARWorldMap, assets: [String: simd_float4x4], startCameraTransform: simd_float4x4?)? {
        let id = roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            print("[RoomLibrary] ❌ Empty roomId provided")
            return nil
        }

        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let worldMapURL = docs.appendingPathComponent("testing_\(id)").appendingPathExtension("arworldmap")
        let assetsURL = docs.appendingPathComponent("testing_\(id)_assets").appendingPathExtension("json")

        // print("[RoomLibrary] 🔍 Looking for ARWorldMap at: \(worldMapURL.path)")
        // print("[RoomLibrary] 🔍 Looking for assets at: \(assetsURL.path)")

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
            var startCameraTransform: simd_float4x4?
            if fm.fileExists(atPath: assetsURL.path) {
                let assetsData = try Data(contentsOf: assetsURL)
                let decoded = try JSONDecoder().decode(TestingRoomData.self, from: assetsData)
                assets = decoded.getAssetTransforms()
                startCameraTransform = decoded.getStartCameraTransform()
            }

            // print("[RoomLibrary] ✅ Loaded testing room '\(id)' with ARWorldMap and \(assets.count) assets")
            // print("[RoomLibrary] 📋 Asset keys: \(assets.keys.sorted())")
            return (worldMap, assets, startCameraTransform)
        } catch {
            print("[RoomLibrary] ❌ Failed to load testing room '\(id)': \(error.localizedDescription)")
            return nil
        }
    }

    static func calculateGunTransform(roomTransform: simd_float4x4, relativeOffset: SIMD3<Float>, yawOffset: Float = 0) -> simd_float4x4 {
        let roomPosition = SIMD3<Float>(
            roomTransform.columns.3.x,
            roomTransform.columns.3.y,
            roomTransform.columns.3.z
        )

        let rotationMatrix = simd_float3x3(
            SIMD3<Float>(roomTransform.columns.0.x, roomTransform.columns.0.y, roomTransform.columns.0.z),
            SIMD3<Float>(roomTransform.columns.1.x, roomTransform.columns.1.y, roomTransform.columns.1.z),
            SIMD3<Float>(roomTransform.columns.2.x, roomTransform.columns.2.y, roomTransform.columns.2.z)
        )

        let rotatedOffset = rotationMatrix * relativeOffset
        let gunPosition = roomPosition + rotatedOffset
        var gunTransform = roomTransform

        if yawOffset != 0 {
            let c = cos(yawOffset), s = sin(yawOffset)
            let yawMatrix = simd_float4x4(
                SIMD4<Float>( c, 0, s, 0),
                SIMD4<Float>( 0, 1, 0, 0),
                SIMD4<Float>(-s, 0, c, 0),
                SIMD4<Float>( 0, 0, 0, 1)
            )
            gunTransform = matrix_multiply(gunTransform, yawMatrix)
        }

        gunTransform.columns.3 = SIMD4<Float>(gunPosition.x, gunPosition.y, gunPosition.z, 1.0)
        return gunTransform
    }

    static func startAlignmentStatus(currentCameraTransform: simd_float4x4, targetStartTransform: simd_float4x4) -> StartPositionAlignmentStatus {
        let currentPos = SIMD3<Float>(currentCameraTransform.columns.3.x, 0, currentCameraTransform.columns.3.z)
        let targetPos = SIMD3<Float>(targetStartTransform.columns.3.x, 0, targetStartTransform.columns.3.z)
        let horizontalDistance = simd_length(currentPos - targetPos)

        func yawDegrees(_ t: simd_float4x4) -> Float {
            let forward = -SIMD3<Float>(t.columns.2.x, 0, t.columns.2.z)
            let normalized = simd_length(forward) > 0.0001 ? simd_normalize(forward) : SIMD3<Float>(0, 0, -1)
            return atan2f(normalized.x, normalized.z) * 180 / .pi
        }

        let currentYaw = yawDegrees(currentCameraTransform)
        let targetYaw = yawDegrees(targetStartTransform)
        var delta = currentYaw - targetYaw
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }

        return StartPositionAlignmentStatus(
            horizontalDistanceMeters: horizontalDistance,
            yawDeltaDegrees: abs(delta)
        )
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
                // print("[RoomLibrary] 🗑️ Deleted world map: \(worldMapURL.lastPathComponent)")
            } catch {
                print("[RoomLibrary] ❌ Failed to delete world map '\(id)': \(error.localizedDescription)")
            }
        }

        if fm.fileExists(atPath: assetsURL.path) {
            do {
                try fm.removeItem(at: assetsURL)
                deletedCount += 1
                // print("[RoomLibrary] 🗑️ Deleted assets: \(assetsURL.lastPathComponent)")
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
                // print("[RoomLibrary] 🗑️ Deleted old format: \(oldFileURL.lastPathComponent)")
            } catch {
                print("[RoomLibrary] ❌ Failed to delete old format '\(id)': \(error.localizedDescription)")
            }
        }

        if deletedCount > 0 {
            // print("[RoomLibrary] ✅ Deleted testing room '\(id)' (\(deletedCount) files)")
        } else {
            // print("[RoomLibrary] ⚠️ No files found to delete for '\(id)'")
        }
    }
}
