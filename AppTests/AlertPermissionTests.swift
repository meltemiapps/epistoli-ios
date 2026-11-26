import Foundation
import Testing
import UserNotifications
@testable import Epistoli

private final class CountingCenter: AlertAuthorizing, @unchecked Sendable {
    var requests = 0
    var grant = true
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requests += 1
        return grant
    }
}

/// "New message" alerts: asked on the first chat open only, never with nothing to push.
@MainActor @Suite struct AlertPermissionTests {
    private func defaults() -> UserDefaults {
        let name = "alerts-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test func asksOnceOnTheFirstChatOpen() async {
        let center = CountingCenter()
        var registered = 0
        let alerts = AlertPermission(center: center, defaults: defaults(), canPush: true) { registered += 1 }
        #expect(!alerts.hasAsked && center.requests == 0)   // nothing at launch
        #expect(await alerts.chatOpened())
        #expect(!(await alerts.chatOpened()))
        #expect(center.requests == 1 && registered == 1)
    }

    @Test func refusalIsRememberedAndNotRegistered() async {
        let center = CountingCenter()
        center.grant = false
        var registered = 0
        let store = defaults()
        let alerts = AlertPermission(center: center, defaults: store, canPush: true) { registered += 1 }
        await alerts.chatOpened()
        // A relaunch doesn't ask again.
        let again = AlertPermission(center: center, defaults: store, canPush: true) { registered += 1 }
        #expect(!(await again.chatOpened()))
        #expect(center.requests == 1 && registered == 0)
    }

    @Test func neverAsksWithoutPush() async {
        let center = CountingCenter()
        let alerts = AlertPermission(center: center, defaults: defaults(), canPush: false) {}
        #expect(!(await alerts.chatOpened()))
        #expect(center.requests == 0)
    }

    @Test func alertTextHasNoContent() {
        #expect(TransportKind.cloudkit.hasPushAlerts && !TransportKind.loopback.hasPushAlerts)
    }
}
