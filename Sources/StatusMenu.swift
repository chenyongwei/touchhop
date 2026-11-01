// Copyright (c) 2026 chenyongwei. SPDX-License-Identifier: MIT

import AppKit

extension AppDelegate {
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "TouchHopStatusItem"
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "cursorarrow.motionlines", accessibilityDescription: "TouchHop") {
                image.isTemplate = true
                button.image = image
            } else { button.title = "TH" }
            button.setAccessibilityLabel(L("menu.accessibility"))
            button.toolTip = "TouchHop"
        }
        let menu = NSMenu()
        menuStatus = NSMenuItem(title: "TouchHop", action: nil, keyEquivalent: "")
        menu.addItem(menuStatus)
        menu.addItem(.separator())
        func add(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
            return item
        }
        _ = add(L("menu.settings"), #selector(showWindow), key: ",")
        _ = add(L("menu.preview"), #selector(previewCursorBeacon))
        menu.addItem(.separator())
        menuTouchToggle = add(L("menu.touch"), #selector(toggle))
        menuShortcutToggle = add(L("menu.shortcut"), #selector(toggleShortcutFromMenu))
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: L("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        statusItem.menu = menu
    }

    func updateStatusItem() {
        menuStatus.title = "TouchHop · \(summaryLabel.stringValue.replacingOccurrences(of: "● ", with: ""))"
        menuTouchToggle.state = mapper.running ? .on : .off
        menuShortcutToggle.state = isShortcutEnabled ? .on : .off
        statusItem.button?.toolTip = "\(menuStatus.title)\n\(mapper.message)"
    }

    @objc func toggleShortcutFromMenu() {
        shortcutEnabled.state = isShortcutEnabled ? .off : .on
        toggleReturnShortcut()
        refreshStatus()
    }
}
