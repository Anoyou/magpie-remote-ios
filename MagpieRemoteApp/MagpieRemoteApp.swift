import SwiftUI

@main
struct MagpieRemoteApp: App {
    @State private var model = AppModel(environment: .current)

    var body: some Scene {
        WindowGroup {
            MainTabs()
                .environment(model)
                .task { await model.start() }
        }
    }
}
