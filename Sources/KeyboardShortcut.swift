// Copyright (c) 2026 chenyongwei. SPDX-License-Identifier: MIT

import AppKit
import Carbon
import CoreGraphics
import IOKit.hid
import ApplicationServices

// Device-specific modifier masks from Apple's IOLLEvent.h distinguish the two sides.
let modifierDeviceMasks: [UInt32: UInt64] = [54: 0x10, 55: 0x08, 56: 0x02, 60: 0x04,
                                           59: 0x01, 62: 0x2000, 58: 0x20, 61: 0x40, 63: 0x800000]
let allDeviceModifiers: UInt64 = 0x207F | 0x800000

func carbonModifiers(_ flags: CGEventFlags) -> UInt32 {
    var result: UInt32 = 0
    if flags.contains(.maskControl) { result |= UInt32(controlKey) }
    if flags.contains(.maskAlternate) { result |= UInt32(optionKey) }
    if flags.contains(.maskShift) { result |= UInt32(shiftKey) }
    if flags.contains(.maskCommand) { result |= UInt32(cmdKey) }
    return result
}

func modifierFlag(_ keyCode: UInt32) -> UInt32 {
    switch keyCode {
    case 54, 55: return UInt32(cmdKey)
    case 56, 60: return UInt32(shiftKey)
    case 58, 61: return UInt32(optionKey)
    case 59, 62: return UInt32(controlKey)
    default: return 0
    }
}

struct ModifierTapRecognizer {
    let keyCode: UInt32
    private(set) var held = false
    private var armed = false

    mutating func cancel() { armed = false }
    mutating func flagsChanged(key: UInt32, flags: CGEventFlags) -> Bool {
        guard key == keyCode, let deviceMask = modifierDeviceMasks[keyCode] else { cancel(); return false }
        let down = flags.rawValue & deviceMask != 0
        if down {
            if !held {
                let soloDevice = flags.rawValue & allDeviceModifiers == deviceMask
                let soloModifier = carbonModifiers(flags) == modifierFlag(keyCode)
                armed = soloDevice && soloModifier
            }
            held = true
            return false
        }
        let fire = held && armed && carbonModifiers(flags) == 0 && flags.rawValue & allDeviceModifiers == 0
        held = false
        armed = false
        return fire
    }
}

struct KeyboardShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let allowedModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)
    static let defaultReturn = KeyboardShortcut(keyCode: UInt32(kVK_RightCommand), modifiers: 0)!
    static let legacyDefault = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(controlKey | optionKey))!
    var isSingle: Bool { modifiers == 0 }
    var isModifier: Bool { modifierDeviceMasks[keyCode] != nil }

    init?(keyCode: UInt32, modifiers: UInt32) {
        guard keyCode < 127, keyCode != UInt32(kVK_Escape), keyCode != UInt32(kVK_CapsLock),
              modifiers & ~Self.allowedModifiers == 0,
              modifierDeviceMasks[keyCode] == nil || modifiers == 0 else { return nil }
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
        54: "右 Command ⌘", 55: "左 Command ⌘", 56: "左 Shift ⇧", 60: "右 Shift ⇧",
        58: "左 Option ⌥", 61: "右 Option ⌥", 59: "左 Control ⌃", 62: "右 Control ⌃", 63: "Fn / 🌐",
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
    case inputAccess

    var message: String {
        switch self {
        case .inputAccess: return "单键快捷键需要鼠标控制和输入监控权限，请先允许权限"
        case .systemConflict: return "此组合键已用于系统快捷键，请换一个"
        case .registration(let code):
            return "此组合键无法注册或已被占用（\(code)），请换一个"
        }
    }
}

// Combinations use Carbon. Single keys use a narrowly routed event tap; no text/history is stored.
final class GlobalShortcut {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var sequence: UInt32 = 0
    private var pressed = false
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var modifierTap = ModifierTapRecognizer(keyCode: 54)
    private var singlePressed = false
    private let signature: OSType = 0x54484F50 // THOP
    var shortcut = KeyboardShortcut.defaultReturn
    var onPress: (() -> Void)?
    var isRegistered: Bool { reference != nil || eventTap != nil }

    func register(_ candidate: KeyboardShortcut) throws {
        if candidate == shortcut && isRegistered { return }
        if candidate.isSingle { try registerSingle(candidate); return }
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
        removeEventTap()
        reference = replacement
        sequence = next
        shortcut = candidate
        pressed = false
    }

    private func registerSingle(_ candidate: KeyboardShortcut) throws {
        guard AXIsProcessTrusted(), IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            throw ShortcutError.inputAccess
        }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown,
                                   .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
                return owner.handleSingle(type: type, event: event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { throw ShortcutError.inputAccess }
        pause()
        shortcut = candidate
        modifierTap = ModifierTapRecognizer(keyCode: candidate.keyCode)
        eventTap = tap
        eventSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleSingle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            modifierTap = ModifierTapRecognizer(keyCode: shortcut.keyCode)
            singlePressed = false
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard eventTap != nil else { return Unmanaged.passUnretained(event) }
        let key = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        if shortcut.isModifier {
            if type == .flagsChanged {
                if modifierTap.flagsChanged(key: key, flags: event.flags) { scheduleAction() }
            } else { modifierTap.cancel() }
            // Preserve Command/Shift/etc. for normal combinations, clicks, and system behavior.
            return Unmanaged.passUnretained(event)
        }
        if key == shortcut.keyCode && type == .keyDown {
            if singlePressed { return nil }
            if carbonModifiers(event.flags) == 0 && !event.flags.contains(.maskSecondaryFn) &&
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                singlePressed = true
                scheduleAction()
                return nil
            }
        }
        if key == shortcut.keyCode && type == .keyUp && singlePressed {
            singlePressed = false
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func scheduleAction() {
        let generation = sequence
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRegistered, self.sequence == generation else { return }
            self.onPress?()
        }
    }

    private func removeEventTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let eventSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        eventSource = nil
        eventTap = nil
        singlePressed = false
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
        removeEventTap()
        sequence &+= 1
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
    private var recordingModifier: ModifierTapRecognizer?
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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, self.recording else { return event }
            self.capture(event)
            return nil
        }
    }
    override func keyDown(with event: NSEvent) {
        if recording { capture(event) } else { super.keyDown(with: event) }
    }
    private func capture(_ event: NSEvent) {
        if event.type == .flagsChanged {
            let key = UInt32(event.keyCode)
            let flags = event.cgEvent?.flags ?? CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
            if recordingModifier == nil, modifierDeviceMasks[key] != nil {
                recordingModifier = ModifierTapRecognizer(keyCode: key)
            }
            if recordingModifier?.flagsChanged(key: key, flags: flags) == true,
               onCapture?(KeyboardShortcut(keyCode: key, modifiers: 0)) == true { finishRecording() }
            if carbonModifiers(flags) == 0 && flags.rawValue & allDeviceModifiers == 0 { recordingModifier = nil }
            return
        }
        guard event.type == .keyDown else { recordingModifier?.cancel(); return }
        guard !event.isARepeat else { return }
        recordingModifier?.cancel()
        if event.keyCode == UInt16(kVK_Escape) { cancelRecording(); return }
        if onCapture?(KeyboardShortcut(event: event)) == true { finishRecording() }
    }
    private func finishRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingModifier = nil
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
    private func updateTitle() { title = recording ? "请按单键或组合键…（Esc 取消）" : "\(shortcut.title) · 点击更改" }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

func migratedShortcut(_ saved: KeyboardShortcut?, schema: Int) -> KeyboardShortcut {
    guard let saved else { return .defaultReturn }
    return schema < 3 && saved == .legacyDefault ? .defaultReturn : saved
}
