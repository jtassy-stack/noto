import CryptoKit
import Foundation
import UIKit

/// Disk-backed cache for authenticated ENT workspace photos.
/// Images are stored in <Caches>/noto_ent_photos/ keyed by a sanitized version of their ENT path.
/// This avoids storing binary blobs in SwiftData while still supporting offline display.
actor ENTPhotoCache {
    static let shared = ENTPhotoCache()

    private let cacheDir: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDir = caches.appendingPathComponent("noto_ent_photos", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        } catch {
            NSLog("[noto][error] ENTPhotoCache: cannot create cache dir: %@", error.localizedDescription)
        }
    }

    /// Returns a cached image if available, otherwise downloads it via an authenticated ENTClient.
    func image(for path: String, client: ENTClient) async -> UIImage? {
        let key = cacheKey(for: path)
        let fileURL = cacheDir.appendingPathComponent(key)

        // Return cached image
        if let data = try? Data(contentsOf: fileURL), let img = UIImage(data: data) {
            return img
        }

        // Download and cache
        guard let data = try? await client.fetchData(path: path),
              let img = UIImage(data: data) else { return nil }

        do {
            try data.write(to: fileURL)
        } catch {
            NSLog("[noto][warning] ENTPhotoCache: write failed for %@: %@", path, error.localizedDescription)
        }
        return img
    }

    /// Pre-warms the disk cache for a list of workspace paths.
    /// Already-cached photos return instantly from disk; others are downloaded sequentially
    /// at background priority. Silently ignores failures (e.g. expired session → 401).
    func preload(paths: [String], client: ENTClient) async {
        for path in paths {
            _ = await image(for: path, client: client)
        }
    }

    /// True if the image is already on disk (no network needed).
    func isCached(_ path: String) -> Bool {
        let fileURL = cacheDir.appendingPathComponent(cacheKey(for: path))
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Remove all cached photos (e.g. on logout or child removal).
    func clearAll() throws {
        try FileManager.default.removeItem(at: cacheDir)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private func cacheKey(for path: String) -> String {
        let data = Data(path.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
