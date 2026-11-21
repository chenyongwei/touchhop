// Copyright (c) 2026 chenyongwei. SPDX-License-Identifier: MIT

import AppKit
import ServiceManagement

private let loginItemConfiguredKey = "loginItemConfigured"

extension AppDelegate {
    func configureLoginItem() {
        // Apply the default once. Subsequent launches respect changes made in System Settings.
        if UserDefaults.standard.bool(forKey: loginItemConfiguredKey) {
            refreshLoginItem()
        } else {
            setLoginItem(enabled: true)
        }
    }

    @objc func toggleLoginItem() {
        setLoginItem(enabled: loginItemCheckbox.state == .on)
    }

    @objc func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func setLoginItem(enabled: Bool) {
        let service = SMAppService.mainApp
        let status = service.status
        let registered = status == .enabled || status == .requiresApproval
        loginItemError = nil
        do {
            if enabled && !registered {
                try service.register()
            } else if !enabled && registered {
                try service.unregister()
            }
            UserDefaults.standard.set(true, forKey: loginItemConfiguredKey)
        } catch {
            if enabled && service.status == .requiresApproval {
                UserDefaults.standard.set(true, forKey: loginItemConfiguredKey)
            } else {
                loginItemError = L("login_item.failed", error.localizedDescription)
            }
        }
        refreshLoginItem()
    }

    func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        let needsApproval = status == .requiresApproval
        loginItemCheckbox.state = status == .enabled || needsApproval ? .on : .off
        loginItemSettingsButton.isHidden = !needsApproval
        let message = loginItemError ?? (needsApproval ? L("login_item.approval") : "")
        loginItemStatus.stringValue = message
        loginItemStatus.isHidden = message.isEmpty
    }
}
