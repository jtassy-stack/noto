import Foundation

/// On-device store of the MonLycée news captured at login (title, author,
/// date and link of the school's announcements): a protected file in
/// Application Support, excluded from backups.
///
/// Earlier builds kept the news and the logbook in UserDefaults;
/// `purgeLegacyDefaults` removes what those builds wrote. The logbook now
/// lives in its own protected file (`MonLyceeLogbookStore`).
enum MonLyceeNewsStore {
    static let fileName = "monlycee-news.json"

    /// UserDefaults keys written by earlier builds, removed on every login.
    static let legacyDefaultsKeys = [
        "monlycee_logbook", "monlycee_news",
        "monlycee_zimbra_mail", "monlycee_pronote_html", "monlycee_pronote_url",
    ]

    static func fileURL(in directory: URL? = nil) -> URL {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("noto", isDirectory: true).appendingPathComponent(fileName)
    }

    /// Replaces the stored news. The file is readable only once the device
    /// has been unlocked after boot (background fetch can still read it).
    static func save(_ news: [[String: Any]], in directory: URL? = nil) throws {
        try ProtectedJSONFile.write(news, to: fileURL(in: directory))
    }

    /// The stored news, empty when nothing was captured yet.
    static func load(in directory: URL? = nil) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: fileURL(in: directory)),
              let news = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return news
    }

    static func clear(in directory: URL? = nil) {
        try? FileManager.default.removeItem(at: fileURL(in: directory))
    }

    static func purgeLegacyDefaults(_ defaults: UserDefaults = .standard) {
        for key in legacyDefaultsKeys { defaults.removeObject(forKey: key) }
    }
}

/// On-device store of the MonLycée logbook captured at login: the homework,
/// grades and class of every child, as the MonLycée home page aggregates
/// them. This is what fed a MonLycée child's homework and grades in the
/// builds before the Pronote token login, and it still does whenever no
/// Pronote session is open. A snapshot of the last login, refreshed by each
/// new MonLycée login. Protected file, excluded from backups, never sent
/// anywhere.
enum MonLyceeLogbookStore {
    static let fileName = "monlycee-logbook.json"

    static func fileURL(in directory: URL? = nil) -> URL {
        MonLyceeNewsStore.fileURL(in: directory)
            .deletingLastPathComponent()
            .appendingPathComponent(fileName)
    }

    static func save(_ logbook: [String: Any], in directory: URL? = nil) throws {
        try ProtectedJSONFile.write(logbook, to: fileURL(in: directory))
    }

    /// The stored logbook, nil when nothing was captured yet.
    static func load(in directory: URL? = nil) -> [String: Any]? {
        guard let data = try? Data(contentsOf: fileURL(in: directory)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func clear(in directory: URL? = nil) {
        try? FileManager.default.removeItem(at: fileURL(in: directory))
    }
}

enum ProtectedJSONFile {
    /// Readable only once the device has been unlocked after boot
    /// (background fetch can still read it), excluded from backups.
    static func write(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var marked = url
        try? marked.setResourceValues(values)
    }
}
