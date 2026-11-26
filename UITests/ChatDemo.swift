import XCTest

/// Checkpoint D: two simulators chatting over the loopback folder (scripts/checkpoint_d.sh runs
/// the steps in order, alternating between the two). Not part of CI.
///
/// Inputs (xcodebuild passes TEST_RUNNER_<NAME> as <NAME>):
///   LOOPBACK_ROOT  the folder both simulators share
///   BG             background preset
///   USER_NAME      name to onboard with
///   PEER_CODE      a contact code to paste
///   PEER           the other person's name (the chat row)
///   TEXT           a message to send
///   EXPECT         a message to wait for
///   TAG            screenshot name prefix
final class ChatDemo: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var tag: String { env["TAG"] ?? "step" }
    private var count = 0

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        if let root = env["LOOPBACK_ROOT"] { app.launchArguments += ["-loopback.root", root] }
        if let bg = env["BG"] { app.launchArguments += ["-appearance.background", bg] }
        app.launch()
    }

    private func shot(_ name: String) {
        count += 1
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = String(format: "%@-%02d-%@", tag, count, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func tap(_ id: String, timeout: TimeInterval = 10) {
        let e = element(id)
        XCTAssertTrue(e.waitForExistence(timeout: timeout), "missing \(id)")
        e.tap()
    }

    private func waitForText(_ text: String, timeout: TimeInterval = 60) {
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
                        .waitForExistence(timeout: timeout),
                      "never saw \"\(text)\"")
    }

    private func openChat(_ name: String) {
        tap("chat.\(name)", timeout: 15)
        XCTAssertTrue(element("chat.field").waitForExistence(timeout: 10))
    }

    private func send(_ text: String) {
        let field = element("chat.field")
        field.tap()
        field.typeText(text)
        tap("chat.send")
        waitForText(text, timeout: 10)
        // Hide the keyboard so the screenshot shows the chat.
        app.swipeDown()
    }

    /// Attach › Photos › the first photo in the library.
    private func attachPhoto() {
        tap("chat.attach")
        XCTAssertTrue(element("attach.sheet").waitForExistence(timeout: 5))
        shot("attach-sheet")
        tap("attach.photos")
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 20), "the photo picker showed no photos")
        photo.tap()
        XCTAssertTrue(element("attachment.mine").waitForExistence(timeout: 30))
    }

    // MARK: Steps

    func test1_Onboard() throws {
        let field = element("onboarding.name")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(try XCTUnwrap(env["USER_NAME"]))
        tap("onboarding.create")
        tap("chats.qr")
        app.buttons["My code"].firstMatch.tap()
        XCTAssertTrue(element("mycode.qr").waitForExistence(timeout: 5))
        tap("mycode.copy")
    }

    func test2_AddContact() throws {
        tap("chats.qr")
        app.buttons["Scan"].firstMatch.tap()
        let field = element("scan.paste.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(try XCTUnwrap(env["PEER_CODE"]))
        tap("scan.paste.check.keyboard")
        XCTAssertTrue(element("result.accept").waitForExistence(timeout: 10))
        shot("check-code")
        tap("result.accept")
        tap("header.back")
        sleep(1)
        shot("list")
    }

    /// Opens the chat, sends a text and a photo.
    func test3_SendTextAndPhoto() throws {
        openChat(try XCTUnwrap(env["PEER"]))
        shot("chat-empty")
        send(try XCTUnwrap(env["TEXT"]))
        attachPhoto()
        sleep(1)
        shot("sent")
    }

    /// Waits for the other side's text and photo, then answers with both.
    func test4_ReceiveAndReply() throws {
        openChat(try XCTUnwrap(env["PEER"]))
        waitForText(try XCTUnwrap(env["EXPECT"]))
        XCTAssertTrue(element("attachment.theirs").waitForExistence(timeout: 60))
        sleep(1)
        shot("received")
        send(try XCTUnwrap(env["TEXT"]))
        attachPhoto()
        sleep(1)
        shot("replied")
    }

    /// Sees the reply and opens the photo. Quick Look's close button isn't reachable from UI tests
    /// (it lives in another process), so the step ends with the photo open and the next step starts
    /// from a fresh launch. Closing it by hand is on docs/DEVICE_TEST_CHECKLIST.md.
    func test5_ReceiveAndOpenPhoto() throws {
        openChat(try XCTUnwrap(env["PEER"]))
        waitForText(try XCTUnwrap(env["EXPECT"]))
        let photo = element("attachment.theirs")
        XCTAssertTrue(photo.waitForExistence(timeout: 60))
        sleep(1)
        shot("received-reply")
        photo.tap()
        // Quick Look renders in another process; give a 4 MB photo time to appear.
        sleep(6)
        shot("photo-preview")
    }

    /// Turns PGP off (after confirming) and writes once more.
    func test5b_PGPOff() throws {
        openChat(try XCTUnwrap(env["PEER"]))
        tap("chat.pgp")
        let confirm = element("pgp.confirmOff")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        shot("pgp-off-confirm")
        confirm.tap()
        waitForText("turned PGP off")
        send(try XCTUnwrap(env["TEXT"]))
        sleep(1)
        shot("pgp-off")
    }

    /// Sees the PGP-off notice, then turns PGP back on.
    func test6_SeePGPOffThenOn() throws {
        openChat(try XCTUnwrap(env["PEER"]))
        waitForText(try XCTUnwrap(env["EXPECT"]))
        sleep(1)
        shot("pgp-off-received")
        tap("chat.pgp")
        waitForText("turned PGP on")
        sleep(1)
        shot("pgp-on-again")
    }

    func test7_SimulateNewPhone() throws {
        tap("chats.settings")
        tap("settings.debug.newphone")
        tap("header.back")
        tap("chats.qr")
        app.buttons["My code"].firstMatch.tap()
        XCTAssertTrue(element("mycode.qr").waitForExistence(timeout: 5))
        tap("mycode.copy")
    }

    /// After accepting a pasted key change: the banner in the chat, and the warning before sending.
    func test8_KeyChangeInChat() throws {
        openChat(try XCTUnwrap(env["PEER"]))
        XCTAssertTrue(element("banner.keychange").waitForExistence(timeout: 5))
        sleep(1)
        shot("keychange-banner")
        let field = element("chat.field")
        field.tap()
        field.typeText(try XCTUnwrap(env["TEXT"]))
        tap("chat.send")
        let sendAnyway = app.buttons["Send anyway"].firstMatch
        XCTAssertTrue(sendAnyway.waitForExistence(timeout: 5))
        shot("keychange-warning")
        sendAnyway.tap()
        waitForText(try XCTUnwrap(env["TEXT"]), timeout: 10)
        app.swipeDown()
        sleep(1)
        shot("keychange-sent")
    }

    func test9_ReceiveOnNewPhone() throws {
        openChat(try XCTUnwrap(env["PEER"]))
        waitForText(try XCTUnwrap(env["EXPECT"]))
        sleep(1)
        shot("received-on-new-phone")
    }

    func test10_CreateGroup() throws {
        tap("chats.newGroup")
        let name = element("group.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(try XCTUnwrap(env["GROUP"]))
        tap("group.member.\(try XCTUnwrap(env["PEER"]))")
        shot("new-group")
        tap("group.create")
        XCTAssertTrue(element("chat.field").waitForExistence(timeout: 10))
        send(try XCTUnwrap(env["TEXT"]))
        sleep(1)
        shot("group-sent")
    }

    func test11_SeeGroup() throws {
        let group = try XCTUnwrap(env["GROUP"])
        XCTAssertTrue(element("chat.\(group)").waitForExistence(timeout: 60))
        shot("list-with-group")
        openChat(group)
        waitForText(try XCTUnwrap(env["EXPECT"]))
        sleep(1)
        shot("group-received")
    }
}
