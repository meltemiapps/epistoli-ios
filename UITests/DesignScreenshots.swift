import XCTest

/// Walks every restyled screen on one background for design review (scripts/design_screenshots.sh).
/// Not part of CI. Needs a freshly installed app. Inputs (xcodebuild passes TEST_RUNNER_<NAME> as <NAME>):
///   BG                       aegean, sunset, olive or night
///   USER_NAME                the name to onboard with
///   CODE_A, CODE_B, CODE_B2  contact codes: person A, person B, person B after a new phone
final class DesignScreenshots: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var bg: String { env["BG"] ?? "aegean" }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-appearance.background", bg]
        app.launch()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(bg)-\(name)"
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

    private func openScan() {
        tap("chats.qr")
        let scan = app.buttons["Scan"].firstMatch
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        scan.tap()
    }

    private func paste(_ code: String) {
        let field = element("scan.paste.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(code)
        tap("scan.paste.check.keyboard")
        XCTAssertTrue(element("result.accept").waitForExistence(timeout: 10))
        sleep(1)
    }

    func testDesignTour() throws {
        let name = try XCTUnwrap(env["USER_NAME"])
        let codeA = try XCTUnwrap(env["CODE_A"])
        let codeB = try XCTUnwrap(env["CODE_B"])
        let codeB2 = try XCTUnwrap(env["CODE_B2"])

        // Onboarding.
        let field = element("onboarding.name")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(name)
        shot("01-onboarding")
        tap("onboarding.create")
        XCTAssertTrue(element("chats.qr").waitForExistence(timeout: 10))
        shot("02-list-empty")

        // Add contact: My code, Scan.
        tap("chats.qr")
        XCTAssertTrue(element("mycode.qr").waitForExistence(timeout: 5))
        sleep(1)
        shot("03-my-code")
        app.buttons["Scan"].firstMatch.tap()
        sleep(1)
        shot("04-scan")

        // Person A from a pasted code: Check code, then their page.
        paste(codeA)
        shot("05-check-code-pasted")
        tap("result.accept")
        sleep(1)
        shot("06-contact-unverified")
        tap("header.back")

        // Person B, then B's new key, pasted: the key-change warning, then the banner.
        openScan()
        paste(codeB)
        tap("result.accept")
        sleep(1)
        tap("header.back")
        openScan()
        paste(codeB2)
        shot("07-check-code-key-change")
        tap("result.accept")
        sleep(1)
        shot("08-contact-key-changed")
        app.swipeUp()
        sleep(1)
        shot("08b-contact-key-changed-scrolled")
        tap("header.back")
        sleep(1)
        shot("09-list")

        // Settings, Appearance, Acknowledgements.
        tap("chats.settings")
        sleep(1)
        shot("10-settings")
        tap("settings.appearance")
        sleep(1)
        shot("11-appearance")
        tap("header.back")
        tap("settings.acknowledgements")
        sleep(1)
        shot("12-acknowledgements")
    }
}
