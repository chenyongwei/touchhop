// Copyright (c) 2026 chenyongwei. SPDX-License-Identifier: MIT

import CoreGraphics

struct ScreenDestination: Equatable {
    let id: CGDirectDisplayID
    let bounds: CGRect
    var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
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
    return ordered.map { ScreenDestination(id: $0, bounds: CGDisplayBounds($0)) }
}

func nextScreenDestination(cursor: CGPoint, screens: [ScreenDestination]) -> ScreenDestination? {
    guard cursor.x.isFinite, cursor.y.isFinite else { return nil }
    let valid = screens.filter { !$0.bounds.isNull && !$0.bounds.isInfinite && $0.bounds.width > 1 && $0.bounds.height > 1 }
    guard !valid.isEmpty else { return nil }
    guard let current = valid.firstIndex(where: { $0.bounds.contains(cursor) }) else { return valid.first }
    return valid[(current + 1) % valid.count]
}

func cursorBeaconOrigin(cursor: CGPoint, mainHeight: CGFloat, panelSize: CGFloat) -> CGPoint {
    CGPoint(x: cursor.x - panelSize / 2, y: mainHeight - cursor.y - panelSize / 2)
}
