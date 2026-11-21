// Copyright (c) 2026 chenyongwei. SPDX-License-Identifier: MIT

import AppKit
import CoreGraphics

// Keep the grabbed point under the cursor and fit the window in the usable area
// when possible. For oversized windows, keep the grab point on the target display.
func windowDragDestination(_ preferred: CGPoint, cursor: CGPoint, window: CGRect, visible: CGRect) -> CGPoint {
    func fit(_ position: CGFloat, offset: CGFloat, size: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        let startAligned = lower + offset
        let endAligned = upper - (size - offset)
        let fitted = min(max(position, min(startAligned, endAligned)), max(startAligned, endAligned))
        return min(max(fitted, lower), upper.nextDown)
    }
    return CGPoint(
        x: fit(preferred.x, offset: cursor.x - window.minX, size: window.width, lower: visible.minX, upper: visible.maxX),
        y: fit(preferred.y, offset: cursor.y - window.minY, size: window.height, lower: visible.minY, upper: visible.maxY)
    )
}

func followsWindowDrag(start: CGRect, current: CGRect, from originalCursor: CGPoint, to cursor: CGPoint) -> Bool {
    let dx = current.minX - start.minX
    let dy = current.minY - start.minY
    return current.size == start.size && hypot(dx, dy) >= 1 &&
        hypot(dx - (cursor.x - originalCursor.x), dy - (cursor.y - originalCursor.y)) <= 6
}

final class WindowDrag {
    private struct Grab {
        let id: CGWindowID
        let bounds: CGRect
        let cursor: CGPoint
        var latestDrag: CGPoint?
        var lastCheck: CGEventTimestamp = 0
        var moving = false
    }

    private var grab: Grab?
    private let eventSource: CGEventSource? = {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()

    func observe(_ type: CGEventType, event: CGEvent) {
        switch type {
        case .leftMouseDown:
            grab = nil
            // TouchHop's own touchscreen clicks keep their separate release path.
            guard event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(ProcessInfo.processInfo.processIdentifier),
                  let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                          kCGNullWindowID) as? [[String: Any]] else { return }
            for info in windows {
                guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                      let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                      let bounds = bounds(from: info), bounds.contains(event.location) else { continue }
                grab = Grab(id: id, bounds: bounds, cursor: event.location)
                break
            }
        case .leftMouseDragged:
            // Sample until the window itself starts moving. Continued drags do
            // not need repeated WindowServer queries.
            guard let grab, !grab.moving else { return }
            self.grab?.latestDrag = event.location
            guard event.timestamp >= grab.lastCheck + 30_000_000 else { return }
            self.grab?.lastCheck = event.timestamp
            _ = confirmedGrab()
        case .leftMouseUp, .rightMouseDown, .otherMouseDown:
            reset()
        default:
            break
        }
    }

    func reset() { grab = nil }

    private func confirmedGrab() -> Grab? {
        guard let grab, let latestDrag = grab.latestDrag,
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, grab.id) as? [[String: Any]],
              let info = windows.first, let current = bounds(from: info), current.size == grab.bounds.size,
              grab.moving || followsWindowDrag(start: grab.bounds, current: current, from: grab.cursor, to: latestDrag)
        else { return nil }
        self.grab?.moving = true
        return grab
    }

    func destination(near preferred: CGPoint, on target: ScreenDestination) -> CGPoint? {
        guard let grab = confirmedGrab() else { return nil }
        return windowDragDestination(preferred, cursor: grab.cursor, window: grab.bounds,
                                     visible: visibleDragArea(for: target))
    }

    func postDrag(to destination: CGPoint) -> CGEventTimestamp? {
        guard let eventSource,
              let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged,
                                  mouseCursorPosition: destination, mouseButton: .left) else { return nil }
        // The shortcut's modifiers must not affect the window drag itself.
        event.flags = []
        event.timestamp = mousePositionTimestamp()
        event.post(tap: .cghidEventTap)
        return event.timestamp
    }

    private func bounds(from info: [String: Any]) -> CGRect? {
        guard let dictionary = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary)
    }
}

func visibleDragArea(for target: ScreenDestination) -> CGRect {
    guard let screen = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == target.id
    }) else { return target.bounds }
    let visible = screen.visibleFrame
    let bounds = CGRect(x: target.bounds.minX + visible.minX - screen.frame.minX,
                        y: target.bounds.minY + screen.frame.maxY - visible.maxY,
                        width: visible.width, height: visible.height)
    let clipped = bounds.intersection(target.bounds)
    return clipped.width > 2 && clipped.height > 2 ? clipped.insetBy(dx: 1, dy: 1) : target.bounds
}
