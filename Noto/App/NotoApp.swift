import SwiftUI
import SwiftData

@main
struct NotoApp: App {
    private let appearance = AppearanceManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(appearance.preference.colorScheme)
                .environment(appearance)
        }
        .modelContainer(for: [
            Family.self,
            Child.self,
            Grade.self,
            ScheduleEntry.self,
            Homework.self,
            Message.self,
            Curriculum.self,
            CultureReco.self,
            Insight.self,
        ])
    }
}
