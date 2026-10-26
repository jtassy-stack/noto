import Foundation

/// On-device store of the MonLycée news captured at login (title, author,
/// date and link of the school's announcements): a protected file in
/// Application Support, excluded from backups.
///
/// Earlier builds kept the news in UserDefaults next to a frozen copy of
/// the whole MonLycée logbook (homework and grades of every child, read
/// once at login and never refreshed). School data now comes from the
/// Pronote session the ENT login opens, so the logbook is no longer stored
/// anywhere; `purgeLegacyDefaults` removes what those builds wrote.
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
        let url = fileURL(in: directory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: news)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var marked = url
        try? marked.setResourceValues(values)
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
