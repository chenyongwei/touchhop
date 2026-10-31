// Copyright (c) 2026 chenyongwei. SPDX-License-Identifier: MIT

import AppKit
import CoreGraphics

private final class EnlargedCursorView: NSView {
    var image = NSCursor.arrow.image
    var hotspot = NSCursor.arrow.hotSpot
    var progress: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = 27 + 12 * sin(progress * .pi)
        NSColor.systemYellow.withAlphaComponent(0.75 * (1 - progress * 0.6)).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                             width: radius * 2, height: radius * 2))
        ring.lineWidth = 3
        ring.stroke()
        let scale = min(3, 82 / max(1, max(image.size.width, image.size.height)))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = CGRect(x: center.x - hotspot.x * scale,
                          y: center.y - (image.size.height - hotspot.y) * scale,
                          width: size.width, height: size.height)
        image.draw(in: rect)
    }
}

// A temporary, click-through enlarged pointer follows the real pointer without changing system preferences.
final class CursorBeacon {
    private let size: CGFloat = 180
    private var panel: NSPanel?
    private var view: EnlargedCursorView?
    private var timer: Timer?
    private var started: TimeInterval = 0

    func show(at point: CGPoint) {
        stop()
        let cursor = NSCursor.currentSystem ?? .arrow
        let view = EnlargedCursorView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        view.image = cursor.image
        view.hotspot = cursor.hotSpot
        let panel = NSPanel(contentRect: view.bounds, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "TouchHop 指针放大提示"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = view
        self.panel = panel
        self.view = view
        started = ProcessInfo.processInfo.systemUptime
        position(at: point)
        panel.orderFrontRegardless()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func position(at point: CGPoint) {
        let origin = cursorBeaconOrigin(cursor: point, mainHeight: CGDisplayBounds(CGMainDisplayID()).height, panelSize: size)
        panel?.setFrameOrigin(origin)
    }
    private func tick() {
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        guard elapsed < 1.0 else { stop(); return }
        if let point = CGEvent(source: nil)?.location { position(at: point) }
        view?.progress = CGFloat(elapsed)
        view?.needsDisplay = true
        panel?.alphaValue = elapsed < 0.7 ? 1 : CGFloat((1 - elapsed) / 0.3)
    }
    func stop() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        view = nil
    }
    deinit { stop() }
}
