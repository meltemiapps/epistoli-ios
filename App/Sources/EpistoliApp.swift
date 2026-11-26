import SwiftUI

@main
struct EpistoliApp: App {
    @State private var model: AppModel
    @State private var appearance = Appearance()

    init() {
        BrandGuard.verify()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(appearance)
        }
    }
}
