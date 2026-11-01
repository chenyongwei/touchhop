// Copyright (c) 2026 chenyongwei. SPDX-License-Identifier: MIT

import AppKit

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class SettingsCard: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        layer?.borderWidth = 0.5
        layer?.cornerRadius = 12
    }
}

extension AppDelegate {
    private func column(spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func fill(_ view: NSView, in stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func row(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }

    private func note(_ text: String) -> NSTextField {
        let field = label(text, size: 12)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func fieldName(_ text: String) -> NSTextField {
        let field = label(text, size: 13)
        let names = [L("settings.target"), L("settings.orientation"), L("shortcut.field"), L("highlight.field")]
        let width = names.map { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width }.max() ?? 66
        field.widthAnchor.constraint(equalToConstant: max(66, ceil(width) + 2)).isActive = true
        return field
    }

    private func symbol(_ name: String, description: String, size: CGFloat = 18) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
        let view = NSImageView(image: image ?? NSImage())
        view.contentTintColor = .controlAccentColor
        view.widthAnchor.constraint(equalToConstant: size + 4).isActive = true
        return view
    }

    private func card(title: String, icon: String, accessory: NSView? = nil,
                      content: (NSStackView) -> Void) -> NSView {
        let card = SettingsCard()
        card.wantsLayer = true
        let stack = column()
        var heading: [NSView] = [symbol(icon, description: title), label(title, size: 14, bold: true), spacer()]
        if let accessory { heading.append(accessory) }
        fill(row(heading, spacing: 8), in: stack)
        content(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18)
        ])
        return card
    }

    func buildSettingsWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 710),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "TouchHop"
        window.minSize = NSSize(width: 580, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = SettingsDocumentView()
        scroll.documentView = document
        window.contentView = scroll

        let stack = column(spacing: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20)
        ])

        let identity = column(spacing: 4)
        identity.addArrangedSubview(label("TouchHop", size: 25, bold: true))
        identity.addArrangedSubview(note(L("app.tagline")))
        summaryLabel = label(L("app.ready"), size: 12, bold: true)
        summaryLabel.setContentHuggingPriority(.required, for: .horizontal)
        fill(row([symbol("cursorarrow.motionlines", description: "TouchHop", size: 30), identity, spacer(), summaryLabel]), in: stack)
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        toggleButton = button(L("touch.enable"), action: #selector(toggle))
        toggleButton.bezelStyle = .rounded
        fill(card(title: L("settings.touch"), icon: "display", accessory: toggleButton) { body in
            displayPicker = NSPopUpButton()
            displayPicker.target = self
            displayPicker.action = #selector(changeDisplay)
            displayPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
            fill(row([fieldName(L("settings.target")), displayPicker]), in: body)
            rotationPicker = NSPopUpButton()
            rotationPicker.addItems(withTitles: [L("rotation.0"), L("rotation.90"), L("rotation.180"), L("rotation.270")])
            rotationPicker.target = self
            rotationPicker.action = #selector(changeRotation)
            rotationPicker.selectItem(at: UserDefaults.standard.integer(forKey: "rotation") / 90)
            fill(row([fieldName(L("settings.orientation")), rotationPicker, spacer()]), in: body)
            statusLabel = note(L("touch.inactive"))
            fill(statusLabel, in: body)
        }, in: stack)

        shortcutEnabled = NSButton(checkboxWithTitle: L("common.enabled"), target: self, action: #selector(toggleReturnShortcut))
        shortcutEnabled.setAccessibilityLabel(L("shortcut.enable"))
        fill(card(title: L("shortcut.section"), icon: "keyboard", accessory: shortcutEnabled) { body in
            shortcutRecorder = ShortcutRecorderButton()
            shortcutRecorder.bezelStyle = .rounded
            fill(row([fieldName(L("shortcut.field")), shortcutRecorder, spacer(), button(L("shortcut.reset"), action: #selector(resetReturnShortcut))]), in: body)
            fill(note(L("shortcut.restore_hint")), in: body)
            fill(row([fieldName(L("highlight.field")), label(L("highlight.style"), size: 13), spacer(),
                      button(L("highlight.preview"), action: #selector(previewCursorBeacon))]), in: body)
            let hint = note(L("shortcut.hint"))
            fill(hint, in: body)
            shortcutStatus = note("")
            fill(shortcutStatus, in: body)
        }, in: stack)

        fill(card(title: L("permissions.section"), icon: "checkmark.shield") { body in
            controlStateLabel = label(L("permissions.pending"), size: 12)
            monitoringStateLabel = label(L("permissions.pending"), size: 12)
            controlPermissionButton = button(L("permissions.allow_control"), action: #selector(requestControl))
            monitoringPermissionButton = button(L("permissions.allow_monitoring"), action: #selector(openMonitoring))
            fill(row([label(L("permissions.control"), size: 13), spacer(), controlStateLabel, controlPermissionButton]), in: body)
            fill(row([label(L("permissions.monitoring"), size: 13), spacer(), monitoringStateLabel, monitoringPermissionButton]), in: body)
            detailsButton = button(L("details.show"), action: #selector(toggleConnectionDetails))
            detailsButton.bezelStyle = .inline
            body.addArrangedSubview(detailsButton)
            dataLabel = note(L("details.no_reports"))
            dataLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            dataLabel.isHidden = true
            fill(dataLabel, in: body)
        }, in: stack)

        fill(row([symbol("menubar.rectangle", description: L("footer.menu_bar"), size: 14),
                  note(L("footer.background"))], spacing: 7), in: stack)
        window.center()
    }

    @objc func toggleConnectionDetails() {
        dataLabel.isHidden.toggle()
        detailsButton.title = dataLabel.isHidden ? L("details.show") : L("details.hide")
    }
}
