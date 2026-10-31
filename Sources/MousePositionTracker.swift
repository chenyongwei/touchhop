// Copyright (c) 2026 chenyongwei. SPDX-License-Identifier: MIT

import CoreGraphics
import CoreFoundation
import ApplicationServices
import IOKit.hid
import Dispatch

// Newly created CGEvents have timestamp zero until posted; snapshots need the same uptime clock as input events.
func mousePositionTimestamp() -> CGEventTimestamp { DispatchTime.now().uptimeNanoseconds }

// Passive mouse-only observation. Events are never swallowed or changed, and no trajectory is stored.
final class MousePositionTracker {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var screens: [ScreenDestination] = []
    private var geometryTimestamp: CGEventTimestamp = 0
    var onPosition: ((CGPoint, CGEventTimestamp, [ScreenDestination]) -> Void)?
    var isRunning: Bool { tap != nil }

    func updateScreens(_ screens: [ScreenDestination], since timestamp: CGEventTimestamp) {
        self.screens = screens
        geometryTimestamp = timestamp
    }

    @discardableResult func start() -> Bool {
        if isRunning { return true }
        guard AXIsProcessTrusted(), IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return false }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
            options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
                if let context {
                    Unmanaged<MousePositionTracker>.fromOpaque(context).takeUnretainedValue().receive(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { CFMachPortInvalidate(tap); return false }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        captureCurrentPosition()
        return true
    }

    func captureCurrentPosition() {
        guard isRunning, let current = CGEvent(source: nil) else { return }
        onPosition?(current.location, mousePositionTimestamp(), screens)
    }

    private func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard tap != nil, event.timestamp >= geometryTimestamp else { return }
        onPosition?(event.location, event.timestamp, screens)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }
    deinit { stop() }
}
