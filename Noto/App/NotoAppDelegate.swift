@preconcurrency import CloudKit
import UIKit

/// Only here to route CloudKit invitations (family sync, phase 9.2): iOS
/// delivers an accepted share link to the window scene's delegate, which a
/// SwiftUI `WindowGroup` does not expose.
final class NotoAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = NotoSceneDelegate.self
        return configuration
    }
}

final class NotoSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Cold launch from an invitation.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            FamilySyncInbox.shared.receive(metadata)
        }
    }

    /// App already running.
    func windowScene(_ windowScene: UIWindowScene,
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        FamilySyncInbox.shared.receive(cloudKitShareMetadata)
    }
}
