import CryptoKit
import Foundation
import UIKit

/// Disk-backed cache for authenticated ENT workspace photos.
/// Images are stored in <Caches>/noto_ent_photos/ keyed by SHA256 of the ENT path.
/// Downloads run concurrently via detached tasks; the actor only serializes dict lookups
/// and disk-cache reads, releasing its lock while awaiting the network.
actor ENTPhotoCache {
    static let shared = ENTPhotoCache()

    private let cacheDir: URL

    /// In-flight download tasks keyed by ENT path.
    /// Stored with a nonce so clearAll() cancellations don't clobber a subsequent task
    /// registered for the same path before the original caller's cleanup runs.
    private var inFlight: [String: (nonce: UUID, task: Task<UIImage?, Never>)] = [:]

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
    /// Multiple concurrent callers for the same path share a single download task.
    /// Different paths download concurrently — the actor lock is released during network I/O.
    func image(for path: String, client: ENTClient) async -> UIImage? {
        let key = cacheKey(for: path)
        let fileURL = cacheDir.appendingPathComponent(key)

        // Fast path: disk cache hit (no network)
        if let data = try? Data(contentsOf: fileURL), let img = UIImage(data: data) {
            return img
        }

        // Deduplicate: reuse an existing in-flight download for the same path
        if let entry = inFlight[path] {
            return await entry.task.value  // releases actor lock while waiting
        }

        // Launch a detached download task so it doesn't run on the actor executor
        let nonce = UUID()
        let task = Task<UIImage?, Never>.detached {
            guard let data = try? await client.fetchData(path: path),
                  let img = UIImage(data: data) else { return nil }
            do {
                try data.write(to: fileURL)
            } catch {
                NSLog("[noto][warning] ENTPhotoCache: write failed for %@: %@", path, error.localizedDescription)
            }
            return img
        }
        inFlight[path] = (nonce: nonce, task: task)
        let result = await task.value  // releases actor lock — other paths download concurrently
        // Only remove if our task is still the registered one (clearAll may have removed it,
        // and a subsequent caller may have registered a new task for the same path).
        if inFlight[path]?.nonce == nonce {
            inFlight[path] = nil
        }
        return result
    }

    /// Pre-warms the disk cache for a list of workspace paths.
    /// Caps concurrency at 4 to avoid overwhelming the ENT server.
    func preload(paths: [String], client: ENTClient) async {
        await withTaskGroup(of: Void.self) { group in
            let maxConcurrent = 4
            var started = 0
            for path in paths {
                if started >= maxConcurrent { await group.next() }
                group.addTask { _ = await self.image(for: path, client: client) }
                started += 1
            }
        }
    }

    /// True if the image is already on disk (no network needed).
    func isCached(_ path: String) -> Bool {
        let fileURL = cacheDir.appendingPathComponent(cacheKey(for: path))
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Remove all cached photos (e.g. on logout or child removal).
    func clearAll() throws {
        for entry in inFlight.values { entry.task.cancel() }
        inFlight.removeAll()
        try FileManager.default.removeItem(at: cacheDir)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private func cacheKey(for path: String) -> String {
        let data = Data(path.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
