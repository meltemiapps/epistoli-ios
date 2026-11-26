import SwiftUI

@main
struct EpistoliApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
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
                .onReceive(NotificationCenter.default.publisher(for: AppDelegate.fetchRequested)) { _ in
                    Task { await model.receiveNow() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.receiveNow() } }
                    if phase == .background, model.transportKind == .cloudkit { AppDelegate.scheduleRefresh() }
                }
        }
    }
}
