import SwiftUI

@main
struct EpistoliApp: App {
    init() {
        BrandGuard.verify()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
