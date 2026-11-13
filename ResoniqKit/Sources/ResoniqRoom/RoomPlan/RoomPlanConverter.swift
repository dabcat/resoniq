#if canImport(RoomPlan)
import Foundation
import RoomPlan
import simd

/// Destructures RoomPlan's `CapturedRoom` into `RoomPlanMapping`'s primitive inputs and nothing more: every rule
/// lives in `RoomPlanMapping.assemble` and is tested on the Mac (RoomScan's `CapturedRoomAdapter`).
///
/// Behind `canImport(RoomPlan)`: the package also builds for macOS, where RoomPlan is absent. `CapturedRoom` is
/// `Sendable`, so these run off the main actor.
public enum RoomPlanConverter {
    /// A finished scan as the app's room, with a guessed seat and stereo pair (`LayoutGuess`, `isConfirmed ==
    /// false`), the items RoomPlan was unsure of and what was dropped.
    public static func conversion(from room: CapturedRoom) -> RoomPlanMapping.Conversion {
        var conversion = assemble(room)
        conversion.room = LayoutGuess.place(in: conversion.room)
        return conversion
    }

    /// A finished scan as the app's room, speakers and seat guessed.
    public static func room(from room: CapturedRoom) -> RoomModel { conversion(from: room).room }

    /// An in-progress scan for the live inset and the wall count, on each delegate update: no layout guess.
    public static func partial(from room: CapturedRoom) -> RoomModel { assemble(room).room }

    /// Where the labels over the camera go.
    public static func markers(from room: CapturedRoom) -> [ScanMarker] {
        RoomPlanMapping.markers(
            walls: room.walls.map(surface), openings: openings(of: room), objects: room.objects.map(object))
    }

    // MARK: Destructuring

    static func assemble(_ room: CapturedRoom) -> RoomPlanMapping.Conversion {
        RoomPlanMapping.assemble(
            walls: room.walls.map(surface), openings: openings(of: room), objects: room.objects.map(object),
            floors: room.floors.map(floor))
    }

    static func openings(of room: CapturedRoom) -> [RoomPlanMapping.SurfaceInput] {
        (room.doors + room.windows + room.openings).map(surface)
    }

    static func surface(_ surface: CapturedRoom.Surface) -> RoomPlanMapping.SurfaceInput {
        RoomPlanMapping.SurfaceInput(
            id: surface.identifier, parentID: surface.parentIdentifier, kind: kind(surface.category),
            confidence: confidence(surface.confidence), transform: widen(surface.transform),
            width: Double(surface.dimensions.x), height: Double(surface.dimensions.y))
    }

    static func object(_ object: CapturedRoom.Object) -> RoomPlanMapping.ObjectInput {
        RoomPlanMapping.ObjectInput(
            id: object.identifier, categoryName: categoryName(object.category),
            confidence: confidence(object.confidence), transform: widen(object.transform),
            width: Double(object.dimensions.x), height: Double(object.dimensions.y),
            depth: Double(object.dimensions.z))
    }

    static func floor(_ surface: CapturedRoom.Surface) -> RoomPlanMapping.FloorInput {
        RoomPlanMapping.FloorInput(
            corners: surface.polygonCorners.map { (x: Double($0.x), y: Double($0.y), z: Double($0.z)) },
            transform: widen(surface.transform))
    }

    /// 16 numbers, column-major, widened to `Double` (RoomScan's `SurfaceMapping.widen`).
    static func widen(_ m: simd_float4x4) -> [Double] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap {
            [Double($0.x), Double($0.y), Double($0.z), Double($0.w)]
        }
    }

    /// A floor reaching the walls list is not expected; it is read as a wall and its zero width drops it.
    static func kind(_ category: CapturedRoom.Surface.Category) -> RoomPlanMapping.SurfaceInput.Kind {
        switch category {
        case .wall, .floor: .wall
        case .door: .door
        case .window: .window
        case .opening: .opening
        @unknown default: .wall
        }
    }

    static func confidence(_ confidence: CapturedRoom.Confidence) -> RoomPlanMapping.Confidence {
        switch confidence {
        case .high: .high
        case .medium: .medium
        case .low: .low
        @unknown default: .low
        }
    }

    /// The case name, which `RoomPlanMapping.category(named:)` reads; unknown future cases are `"unknown"`.
    static func categoryName(_ category: CapturedRoom.Object.Category) -> String {
        switch category {
        case .storage: "storage"
        case .refrigerator: "refrigerator"
        case .stove: "stove"
        case .bed: "bed"
        case .sink: "sink"
        case .washerDryer: "washerDryer"
        case .toilet: "toilet"
        case .bathtub: "bathtub"
        case .oven: "oven"
        case .dishwasher: "dishwasher"
        case .table: "table"
        case .sofa: "sofa"
        case .chair: "chair"
        case .fireplace: "fireplace"
        case .television: "television"
        case .stairs: "stairs"
        @unknown default: "unknown"
        }
    }
}
#endif
