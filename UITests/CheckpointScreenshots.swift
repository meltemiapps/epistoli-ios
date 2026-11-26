import XCTest

/// Drives the real UI on two simulators for checkpoint screenshots. Not part of CI: it needs a
/// second simulator and a code handed over between them (scripts/checkpoint_c.sh does that).
///
/// Inputs come from the environment (xcodebuild passes TEST_RUNNER_<NAME> as <NAME>):
///   USER_NAME  the name to onboard with
///   PEER_CODE  a contact code to paste
final class CheckpointScreenshots: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func tap(_ id: String, timeout: TimeInterval = 10) {
        let e = element(id)
        XCTAssertTrue(e.waitForExistence(timeout: timeout), "missing \(id)")
        e.tap()
    }

    private func openKeyExchange(_ mode: String) {
        tap("chats.qr")
        let button = app.buttons[mode].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }

    func test1_OnboardAndShowMyCode() throws {
        let name = try XCTUnwrap(env["USER_NAME"])
        let field = element("onboarding.name")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(name)
        shot("01-onboarding")
        tap("onboarding.create")
        XCTAssertTrue(element("chats.qr").waitForExistence(timeout: 10))
        shot("02-empty-list")
        openKeyExchange("My code")
        XCTAssertTrue(element("mycode.qr").waitForExistence(timeout: 5))
        shot("03-my-code")
        tap("mycode.copy")
    }

    func test2_PasteCode() throws {
        let code = try XCTUnwrap(env["PEER_CODE"])
        let tag = env["SHOT_TAG"] ?? "paste"
        openKeyExchange("Scan")
        let field = element("scan.paste.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        shot("\(tag)-1-scan")
        field.tap()
        field.typeText(code)
        tap("scan.paste.check.keyboard")
        XCTAssertTrue(element("result.accept").waitForExistence(timeout: 10))
        shot("\(tag)-2-result")
        // Scroll so the warning and the button are visible too, if the result is long.
        app.swipeUp()
        shot("\(tag)-3-result-scrolled")
        tap("result.accept")
        sleep(1)
        shot("\(tag)-4-contact")
        app.swipeUp()
        shot("\(tag)-5-contact-scrolled")
        tap("header.back")
        sleep(1)
        shot("\(tag)-6-list")
    }

    func test3_SimulateNewPhoneAndShowCode() throws {
        tap("chats.settings")
        tap("settings.debug.newphone")
        sleep(1)
        shot("newphone-1-settings")
        tap("header.back")
        openKeyExchange("My code")
        XCTAssertTrue(element("mycode.qr").waitForExistence(timeout: 5))
        shot("newphone-2-my-code")
        tap("mycode.copy")
    }

    func test4_Acknowledgements() throws {
        tap("chats.settings")
        shot("settings-1")
        tap("settings.acknowledgements")
        sleep(1)
        shot("ack-1-list")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'GopenPGP'")).firstMatch.tap()
        sleep(1)
        shot("ack-2-gopenpgp")
        tap("header.back")
        sleep(1)
        app.swipeUp()
        shot("ack-3-list-scrolled")
    }

    func test5_OwnCodeRefused() throws {
        openKeyExchange("My code")
        tap("mycode.copy")
        // Copy reaches the field through the system pasteboard; typing it keeps the test independent of paste prompts.
        let code = try XCTUnwrap(env["OWN_CODE"])
        app.buttons["Scan"].firstMatch.tap()
        let field = element("scan.paste.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(code)
        tap("scan.paste.check.keyboard")
        sleep(1)
        shot("own-code-refused")
    }
}
