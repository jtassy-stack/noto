import Photos
import UIKit

/// Saves ENT school photos to the user's Photos library.
/// Creates a "nōto" album the first time a photo is saved.
enum ENTPhotoSaver {

    /// Save a UIImage to the "nōto" album in the Photos library.
    /// Requests add-only permission if not already granted.
    @MainActor
    static func save(_ image: UIImage) async throws {
        try await requestAddPermissionIfNeeded()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest.creationRequestForAsset(from: image)
            let placeholder = request.placeholderForCreatedAsset

            // Add to the "nōto" album (create if missing)
            if let album = findOrCreateAlbum(), let placeholder {
                album.addAssets([placeholder] as NSFastEnumeration)
            }
        }
    }

    // MARK: - Permission

    private static func requestAddPermissionIfNeeded() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard granted == .authorized || granted == .limited else {
                throw SaveError.denied
            }
        case .denied, .restricted:
            throw SaveError.denied
        @unknown default:
            throw SaveError.denied
        }
    }

    // MARK: - Album

    /// Returns a PHAssetCollectionChangeRequest for the "nōto" album,
    /// creating it first if it doesn't exist.
    /// Must be called inside performChanges { }.
    private static func findOrCreateAlbum() -> PHAssetCollectionChangeRequest? {
        // Find existing album
        let fetchResult = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        )
        var existing: PHAssetCollection?
        fetchResult.enumerateObjects { collection, _, stop in
            if collection.localizedTitle == "nōto" {
                existing = collection
                stop.pointee = true
            }
        }

        if let existing {
            return PHAssetCollectionChangeRequest(for: existing)
        } else {
            return PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "nōto")
        }
    }

    // MARK: - Error

    enum SaveError: LocalizedError {
        case denied

        var errorDescription: String? {
            "Autorisez nōto à ajouter des photos dans Réglages > Confidentialité > Photos."
        }
    }
}
