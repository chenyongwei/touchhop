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
        field.widthAnchor.constraint(equalToConstant: 66).isActive = true
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
        identity.addArrangedSubview(note("触控直达，轻松切屏"))
        summaryLabel = label("准备就绪", size: 12, bold: true)
        summaryLabel.setContentHuggingPriority(.required, for: .horizontal)
        fill(row([symbol("cursorarrow.motionlines", description: "TouchHop", size: 30), identity, spacer(), summaryLabel]), in: stack)
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        toggleButton = button("启用触控定位", action: #selector(toggle))
        toggleButton.bezelStyle = .rounded
        fill(card(title: "触控屏幕", icon: "display", accessory: toggleButton) { body in
            displayPicker = NSPopUpButton()
            displayPicker.target = self
            displayPicker.action = #selector(changeDisplay)
            displayPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
            fill(row([fieldName("目标屏幕"), displayPicker]), in: body)
            rotationPicker = NSPopUpButton()
            rotationPicker.addItems(withTitles: ["正常 · 0°", "顺时针 · 90°", "旋转 · 180°", "逆时针 · 90°"])
            rotationPicker.target = self
            rotationPicker.action = #selector(changeRotation)
            rotationPicker.selectItem(at: UserDefaults.standard.integer(forKey: "rotation") / 90)
            fill(row([fieldName("触控方向"), rotationPicker, spacer()]), in: body)
            statusLabel = note("尚未启用")
            fill(statusLabel, in: body)
        }, in: stack)

        shortcutEnabled = NSButton(checkboxWithTitle: "启用", target: self, action: #selector(toggleReturnShortcut))
        shortcutEnabled.setAccessibilityLabel("启用切屏快捷键")
        fill(card(title: "切屏快捷键", icon: "keyboard", accessory: shortcutEnabled) { body in
            shortcutRecorder = ShortcutRecorderButton()
            shortcutRecorder.bezelStyle = .rounded
            fill(row([fieldName("快捷键"), shortcutRecorder, spacer(), button("恢复默认", action: #selector(resetReturnShortcut))]), in: body)
            fill(note("切回每块屏幕上次离开的位置；首次到达时定位中央。"), in: body)
            fill(row([fieldName("指针提示"), label("炫彩光环与放大指针", size: 13), spacer(),
                      button("预览效果", action: #selector(previewCursorBeacon))]), in: body)
            let hint = note("支持单键或组合键，Esc 取消录入。字母或空格单键会占用该键的普通输入。")
            fill(hint, in: body)
            shortcutStatus = note("")
            fill(shortcutStatus, in: body)
        }, in: stack)

        fill(card(title: "权限与状态", icon: "checkmark.shield") { body in
            controlStateLabel = label("待允许", size: 12)
            monitoringStateLabel = label("待允许", size: 12)
            controlPermissionButton = button("允许控制", action: #selector(requestControl))
            monitoringPermissionButton = button("允许监控", action: #selector(openMonitoring))
            fill(row([label("鼠标控制", size: 13), spacer(), controlStateLabel, controlPermissionButton]), in: body)
            fill(row([label("输入监控", size: 13), spacer(), monitoringStateLabel, monitoringPermissionButton]), in: body)
            detailsButton = button("查看连接详情", action: #selector(toggleConnectionDetails))
            detailsButton.bezelStyle = .inline
            body.addArrangedSubview(detailsButton)
            dataLabel = note("尚未收到触控数据")
            dataLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            dataLabel.isHidden = true
            fill(dataLabel, in: body)
        }, in: stack)

        fill(row([symbol("menubar.rectangle", description: "菜单栏", size: 14),
                  note("关闭窗口后继续在菜单栏运行。")], spacing: 7), in: stack)
        window.center()
    }

    @objc func toggleConnectionDetails() {
        dataLabel.isHidden.toggle()
        detailsButton.title = dataLabel.isHidden ? "查看连接详情" : "收起连接详情"
    }
}
