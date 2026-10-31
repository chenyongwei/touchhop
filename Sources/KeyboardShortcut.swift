// Copyright (c) 2026 chenyongwei. SPDX-License-Identifier: MIT

import AppKit
import Carbon

struct KeyboardShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let allowedModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)
    static let defaultReturn = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_H),
                                                modifiers: UInt32(controlKey | optionKey))!
    private static let modifierKeys: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    init?(keyCode: UInt32, modifiers: UInt32) {
        guard keyCode < 127, keyCode != UInt32(kVK_Escape),
              !Self.modifierKeys.contains(keyCode),
              modifiers & ~Self.allowedModifiers == 0,
              modifiers & UInt32(controlKey | cmdKey) != 0 else { return nil }
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    private enum CodingKeys: String, CodingKey { case keyCode, modifiers }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let key = try values.decode(UInt32.self, forKey: .keyCode)
        let flags = try values.decode(UInt32.self, forKey: .modifiers)
        guard let shortcut = Self(keyCode: key, modifiers: flags) else {
            throw DecodingError.dataCorruptedError(forKey: .keyCode, in: values,
                debugDescription: "Invalid global keyboard shortcut")
        }
        self = shortcut
    }

    var title: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyLabel(keyCode)
    }
}

private func keyLabel(_ code: UInt32) -> String {
    let names: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 76: "⌤", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
        107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]
    if let name = names[code] { return name }
    let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
    guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
        return "按键 \(code)"
    }
    let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
    guard let bytes = CFDataGetBytePtr(data) else { return "按键 \(code)" }
    let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
    var deadState: UInt32 = 0
    var characters = [UniChar](repeating: 0, count: 8)
    var count = 0
    let result = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
        &deadState, characters.count, &count, &characters)
    guard result == noErr, count > 0 else { return "按键 \(code)" }
    return String(utf16CodeUnits: characters, count: count).uppercased()
}

enum ShortcutError: Error {
    case systemConflict
    case registration(OSStatus)

    var message: String {
        switch self {
        case .systemConflict: return "此组合键已用于系统快捷键，请换一个"
        case .registration(let code):
            return "此组合键无法注册或已被占用（\(code)），请换一个"
        }
    }
}

// Carbon delivers only the registered combination. No global key-event monitor is installed.
final class GlobalShortcut {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var sequence: UInt32 = 0
    private var pressed = false
    private let signature: OSType = 0x54484F50 // THOP
    var shortcut = KeyboardShortcut.defaultReturn
    var onPress: (() -> Void)?
    var isRegistered: Bool { reference != nil }

    func register(_ candidate: KeyboardShortcut) throws {
        if candidate == shortcut && reference != nil { return }
        var symbolic: Unmanaged<CFArray>?
        if CopySymbolicHotKeys(&symbolic) == noErr,
           let entries = symbolic?.takeRetainedValue() as? [[String: Any]],
           entries.contains(where: {
               ($0[kHISymbolicHotKeyEnabled as String] as? Bool) == true &&
               ($0[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value == candidate.keyCode &&
               ($0[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value == candidate.modifiers
           }) { throw ShortcutError.systemConflict }

        if handler == nil {
            let events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let result = events.withUnsafeBufferPointer {
                InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                    guard let event, let context else { return OSStatus(eventNotHandledErr) }
                    return Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue().handle(event)
                }, events.count, $0.baseAddress, Unmanaged.passUnretained(self).toOpaque(), &handler)
            }
            guard result == noErr else { throw ShortcutError.registration(result) }
        }
        let next = sequence &+ 1
        var replacement: EventHotKeyRef?
        let result = RegisterEventHotKey(candidate.keyCode, candidate.modifiers,
            EventHotKeyID(signature: signature, id: next), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &replacement)
        guard result == noErr, let replacement else { throw ShortcutError.registration(result) }
        // Keep an existing working registration if the replacement cannot be registered.
        if let reference { UnregisterEventHotKey(reference) }
        reference = replacement
        sequence = next
        shortcut = candidate
        pressed = false
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var identity = EventHotKeyID(signature: 0, id: 0)
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &identity) == noErr,
            reference != nil, identity.signature == signature, identity.id == sequence else {
            return OSStatus(eventNotHandledErr)
        }
        if GetEventKind(event) == UInt32(kEventHotKeyReleased) { pressed = false }
        else if !pressed { pressed = true; onPress?() }
        return noErr
    }

    func pause() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        pressed = false
    }
    deinit {
        pause()
        if let handler { RemoveEventHandler(handler) }
    }
}

final class ShortcutRecorderButton: NSButton {
    var shortcut = KeyboardShortcut.defaultReturn { didSet { updateTitle() } }
    private(set) var recording = false
    var onBegin: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCapture: ((KeyboardShortcut?) -> Bool)?
    private var monitor: Any?
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(toggleRecording)
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        target = self
        action = #selector(toggleRecording)
    }
    @objc private func toggleRecording() {
        if recording { cancelRecording(); return }
        recording = true
        onBegin?()
        updateTitle()
        window?.makeFirstResponder(self)
        // Local to this app and only while recording; also captures Command combinations before menus.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording else { return event }
            self.capture(event)
            return nil
        }
    }
    override func keyDown(with event: NSEvent) {
        if recording { capture(event) } else { super.keyDown(with: event) }
    }
    private func capture(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        if event.keyCode == UInt16(kVK_Escape) { cancelRecording(); return }
        if onCapture?(KeyboardShortcut(event: event)) == true { finishRecording() }
    }
    private func finishRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        updateTitle()
    }
    func cancelRecording() {
        guard recording else { return }
        finishRecording()
        onCancel?()
    }
    override func resignFirstResponder() -> Bool {
        cancelRecording()
        return super.resignFirstResponder()
    }
    private func updateTitle() { title = recording ? "请按组合键…（Esc 取消）" : "\(shortcut.title) · 点击更改" }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

// Core Graphics desktop coordinates, including main displays at nonzero/negative origins in fixtures.
func primaryReturnPoint(cursor: CGPoint, bounds: CGRect) -> CGPoint? {
    guard !bounds.isNull, !bounds.isInfinite, bounds.width > 1, bounds.height > 1,
          cursor.x.isFinite, cursor.y.isFinite, !bounds.contains(cursor) else { return nil }
    return CGPoint(x: bounds.midX, y: bounds.midY)
}
