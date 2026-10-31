// Copyright (c) 2026 chenyongwei. SPDX-License-Identifier: MIT

import CoreGraphics

struct ScreenDestination: Equatable {
    let id: CGDirectDisplayID
    let bounds: CGRect
    let identity: String

    init(id: CGDirectDisplayID, bounds: CGRect, identity: String? = nil) {
        self.id = id
        self.bounds = bounds
        self.identity = identity ?? "display:\(id)"
    }

    var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    var isUsable: Bool {
        !bounds.isNull && !bounds.isInfinite && bounds.minX.isFinite && bounds.minY.isFinite &&
        bounds.width.isFinite && bounds.height.isFinite && bounds.width > 1 && bounds.height > 1
    }
}

func activeCycleScreens() -> [ScreenDestination] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    let main = CGMainDisplayID()
    let active = ids.prefix(Int(count)).filter {
        CGDisplayIsActive($0) != 0 && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay
    }
    let ordered = active.filter { $0 == main } + active.filter { $0 != main }
    return ordered.map { ScreenDestination(id: $0, bounds: CGDisplayBounds($0), identity: uuidForDisplay($0)) }
}

func nextScreenDestination(cursor: CGPoint, screens: [ScreenDestination]) -> ScreenDestination? {
    guard cursor.x.isFinite, cursor.y.isFinite else { return nil }
    let valid = screens.filter(\.isUsable)
    guard !valid.isEmpty else { return nil }
    guard let current = valid.firstIndex(where: { $0.bounds.contains(cursor) }) else { return valid.first }
    return valid[(current + 1) % valid.count]
}

// Only one point per physical display is kept, in memory. Normalized coordinates survive layout changes.
struct ScreenPositionMemory {
    private struct Position {
        let normalized: CGPoint
        let timestamp: CGEventTimestamp
    }
    private var positions: [String: Position] = [:]

    init() {}

    mutating func observe(_ point: CGPoint, screens: [ScreenDestination], timestamp: CGEventTimestamp) {
        guard point.x.isFinite, point.y.isFinite,
              let screen = screens.first(where: { $0.isUsable && $0.bounds.contains(point) }) else { return }
        if let previous = positions[screen.identity], previous.timestamp > timestamp { return }
        let normalized = CGPoint(x: (point.x - screen.bounds.minX) / screen.bounds.width,
                                 y: (point.y - screen.bounds.minY) / screen.bounds.height)
        positions[screen.identity] = Position(normalized: normalized, timestamp: timestamp)
    }

    func hasPosition(for screen: ScreenDestination) -> Bool { positions[screen.identity] != nil }

    func destination(for screen: ScreenDestination) -> CGPoint? {
        guard screen.isUsable else { return nil }
        guard let stored = positions[screen.identity] else { return screen.center }
        let b = screen.bounds
        return CGPoint(x: min(max(b.minX + stored.normalized.x * b.width, b.minX), b.maxX.nextDown),
                       y: min(max(b.minY + stored.normalized.y * b.height, b.minY), b.maxY.nextDown))
    }
}

func cursorBeaconOrigin(cursor: CGPoint, mainHeight: CGFloat, panelSize: CGFloat) -> CGPoint {
    CGPoint(x: cursor.x - panelSize / 2, y: mainHeight - cursor.y - panelSize / 2)
}
