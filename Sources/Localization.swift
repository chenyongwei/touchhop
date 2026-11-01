// Copyright (c) 2026 chenyongwei. SPDX-License-Identifier: MIT

import Foundation

// Bundle selection honors macOS language order and per-app language preferences.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let text = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    guard !arguments.isEmpty else { return text }
    return String(format: text, locale: Locale.current, arguments: arguments)
}

func checkLocalizations(_ require: (Bool, String) -> Void) {
    let languages = ["en", "zh-Hans", "ja"]
    var catalogs: [String: [String: String]] = [:]
    for language in languages {
        let url = Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language)
        let data = url.flatMap { try? Data(contentsOf: $0) }
        let catalog = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: String] }
        require(catalog != nil && url?.deletingLastPathComponent().lastPathComponent == "\(language).lproj",
                "bundled localization: \(language)")
        catalogs[language] = catalog ?? [:]
    }
    let english = catalogs["en"] ?? [:]
    require(!english.isEmpty, "English fallback catalog is populated")
    let pattern = try! NSRegularExpression(pattern: "%(@|ld|u|d)")
    func placeholders(_ value: String) -> [String] {
        pattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }
    for language in languages {
        let catalog = catalogs[language] ?? [:]
        require(Set(catalog.keys) == Set(english.keys), "complete localization keys: \(language)")
        require(catalog.values.allSatisfy { !$0.isEmpty }, "nonempty translations: \(language)")
        require(english.allSatisfy { key, value in placeholders(value) == placeholders(catalog[key] ?? "") },
                "compatible format arguments: \(language)")
        let format = catalog["shortcut.recorder_title"] ?? ""
        require(String(format: format, "⌃⌥H").contains("⌃⌥H"), "shortcut survives localized formatting: \(language)")
    }
}
