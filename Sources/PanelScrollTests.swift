// Copyright (c) 2026 chenyongwei. SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

// Exercise the same decoder, gesture arbitration and scroll deltas as the HID callback,
// substituting a local event sink for posting input to the user's session.
func checkPanelScroll(_ require: (Bool, String) -> Void) {
    let bounds = CGRect(x: -1600, y: 20, width: 1600, height: 900)
    var events: [PanelEvent] = []
    let mapper = TouchMapper { event, _ in events.append(event); return true }
    mapper.doubleClickInterval = { 0.5 }
    let first = 0x03110000, second = 0x03140000
    let anchor = CGPoint(x: -800, y: 470)

    func feed(_ tick: Int8, down: Bool = false, from location: Int, at time: TimeInterval,
              point: CGPoint = CGPoint(x: -800, y: 470), prefixed: Bool = true) {
        let payload: [UInt8] = [down ? 1 : 0, 0x00, 0x20, 0xBF, 0x12, UInt8(bitPattern: tick)]
        let bytes = prefixed ? [UInt8(7)] + payload : payload
        let packet = decodeMouseReport(bytes, reportID: 7, maxX: 16383, maxY: 9599)!
        mapper.handle(packet, at: point, location: location, bounds: bounds, now: time)
    }
    func types() -> [CGEventType] { events.map(\.type) }
    func pixels() -> [Int32] {
        events.filter { $0.type == .scrollWheel }.map(\.verticalPixels)
    }

    feed(0, down: true, from: first, at: 1)
    feed(1, from: first, at: 1.01)
    feed(1, from: second, at: 1.012)
    feed(2, from: first, at: 1.02, point: bounds.origin)
    feed(0, down: true, from: first, at: 1.03)
    feed(0, from: first, at: 1.04)
    require(types() == [.mouseMoved, .mouseMoved, .scrollWheel, .scrollWheel],
            "wheel takes over candidate tap, suppresses duplicate interface and trailing contact")
    require(pixels() == [-8, -16] && events.suffix(2).allSatisfy { $0.point == anchor },
            "upward finger movement scrolls down the same target view in pixels")

    events.removeAll()
    feed(0, down: true, from: first, at: 1.05)
    feed(0, from: first, at: 1.07)
    require(types() == [.mouseMoved, .leftMouseDown, .leftMouseUp], "fresh tap after confirmed scroll liftoff")
    feed(0, down: true, from: first, at: 1.08)
    feed(0, from: first, at: 1.10)
    require(events.last?.clickCount == 2, "double tap still counts twice")
    events.removeAll()
    feed(-3, from: second, at: 2, prefixed: false)
    feed(-3, from: first, at: 2.01)
    feed(-1, from: first, at: 2.22)
    require(pixels() == [24, 8], "negative wheel without report prefix and new owner after quiet interval")

    mapper.suspendTouchForCursorReturn()
    events.removeAll()
    feed(-1, from: first, at: 2.24)
    require(events.isEmpty, "cursor return silences an ongoing wheel gesture")
    feed(1, from: second, at: 3)
    require(pixels() == [-8], "later gesture can resume on either USB interface")
    mapper.stop()
    events.removeAll()
    feed(0, down: true, from: first, at: 4)
    feed(0, down: true, from: first, at: 4.02, point: CGPoint(x: -780, y: 470))
    feed(0, from: first, at: 4.04, point: CGPoint(x: -780, y: 470))
    require(types() == [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp],
            "ordinary single-finger dragging stays balanced")
    events.removeAll()
    feed(0, down: true, from: first, at: 5)
    mapper.stop()
    require(types() == [.mouseMoved], "stop discards uncommitted tap")
}
