import KontalaTestSupport
import XCTest

@testable import KontalaCore

/// What a form sent and who a login names, the Flutter SDK's rules over fields as any toolkit describes them.
final class FormsTests: XCTestCase {
    private func cases(_ key: String) -> [JSONObject] {
        (repoJson("collector/clicks/testdata/vectors.json").list(key) ?? []).compactMap { $0.object }
    }

    func testANameThatSaysItHoldsASecretIsTheCollectors() {
        let all = cases("secret_names")
        XCTAssertFalse(all.isEmpty)
        for c in all {
            XCTAssertEqual(c["secret"]?.bool, Forms.secretName(c.str("in")!), c.str("in")!)
        }
    }

    func testANameAValueMaySendUnderIsTheCollectors() {
        let all = cases("value_names")
        XCTAssertFalse(all.isEmpty)
        for c in all {
            XCTAssertEqual(c["valid"]?.bool, Forms.valueName(c.str("in")!), c.str("in")!)
        }
    }

    private let password = FieldInfo(name: nil, label: "Password", obscured: true, value: "hunter2")

    private func login(_ fields: [FieldInfo], declared: Bool = false) -> [String?]? {
        Forms.loginIn(fields, declared: declared).map { [$0.user, $0.org] }
    }

    func testALoginNamesTheUserItsFieldsSay() {
        XCTAssertEqual(
            ["anna", nil],
            login([
                FieldInfo(name: "email", label: nil, email: true, value: "anna@example.com"),
                FieldInfo(name: "handle", label: nil, hints: [Hints.username], value: " anna "),
                password,
            ]), "a username's hint first")
        XCTAssertEqual(
            ["anna@example.com", nil],
            login([FieldInfo(name: nil, label: "You", email: true, value: "anna@example.com"), password]),
            "an email keyboard's field")
        XCTAssertEqual(
            ["anna", "acme"],
            login([
                FieldInfo(name: "company", label: nil, value: "acme"),
                FieldInfo(name: "login", label: nil, value: "anna"),
                password,
            ]), "a name that says user, beside one that says organisation")
        XCTAssertEqual(
            ["anna", nil], login([FieldInfo(name: nil, label: "Who", value: "anna"), password]),
            "the one typed field left")
    }

    func testAFormIsALoginByItsFieldsOrByWhatTheTapDeclares() {
        let search = [FieldInfo(name: "email", label: nil, email: true, value: "anna@example.com")]
        XCTAssertNil(login(search), "no field hides its text or says username")
        XCTAssertEqual(["anna@example.com", nil], login(search, declared: true), "declared login")
        XCTAssertNil(
            login([FieldInfo(name: "user", label: nil, value: "anna de vries"), password]),
            "a value that is no principal id names no one")
        XCTAssertNil(login([], declared: true), "no fields")
    }

    func testAFormsValuesAreNamedAsTheVisitorEnteredThemAndASecretIsNeverRead() {
        let values = Forms.values([
            .text(FieldInfo(name: "email", label: nil, value: "anna@example.com")),
            .text(password),
            .text(FieldInfo(name: nil, label: nil, value: "unnamed")),
            .text(FieldInfo(name: nil, label: "Delivery note", value: "At the door")),
            .text(
                FieldInfo(
                    name: nil, label: nil, hints: [Hints.cardSecurityCode, "creditCardNumber"], value: "123")),
            .text(FieldInfo(name: "card_pin", label: nil, value: "9876")),
            .choice(name: "size", value: "m"),
            .choice(name: "size", value: "l"),
            .choice(name: "newsletter", value: Forms.text(true)),
            .choice(name: nil, value: "unnamed choice"),
        ])
        XCTAssertEqual(
            [
                "email": "anna@example.com", "field_3": "unnamed", "delivery_note": "At the door", "size": "m|l",
                "newsletter": "true", "field_10": "unnamed choice",
            ], values)
        XCTAssertEqual(["email", "field_3", "delivery_note", "size", "newsletter", "field_10"], values.keys)
    }

    func testAFormSaysWhatItHoldsByKind() {
        XCTAssertEqual(
            ["card", "email", "message", "new_password", "password", "search"],
            Forms.fieldKinds([
                FieldInfo(name: nil, label: nil, hints: [Hints.email]),
                FieldInfo(name: nil, label: nil, hints: [Hints.newPassword], obscured: true),
                FieldInfo(name: nil, label: nil, hints: ["creditCardNumber"]),
                FieldInfo(name: nil, label: nil, multiline: true),
                FieldInfo(name: nil, label: nil, search: true),
            ]))
    }

    func testAChoiceIsSentAsAFormSendsIt() {
        XCTAssertEqual("true", Forms.text(true))
        XCTAssertEqual("3", Forms.text(3.0))
        XCTAssertEqual("2.5", Forms.text(2.5))
        XCTAssertEqual("12", Forms.text(Int64(12)))
        XCTAssertEqual("4", Forms.text(Float(4)))
        XCTAssertNil(Forms.text(NSObject()))
    }

    func testASearchBoxsTermIsCollapsedAndNeverAWithheldFieldsOwn() {
        XCTAssertEqual(
            "Linen shirt", Forms.term(FieldInfo(name: "q", label: nil, search: true, value: " Linen \n shirt ")))
        XCTAssertNil(Forms.term(FieldInfo(name: "q", label: nil, search: true, value: "   ")))
        XCTAssertNil(Forms.term(FieldInfo(name: "pin", label: nil, search: true, value: "1234")))
    }

    func testIOSsContentTypesAreReadAsTheFlutterSDKsHints() {
        XCTAssertEqual(Hints.username, Hints.ofContentType("username"))
        XCTAssertEqual(Hints.newPassword, Hints.ofContentType("new-password"))
        XCTAssertEqual(Hints.oneTimeCode, Hints.ofContentType("one-time-code"))
        XCTAssertEqual(Hints.email, Hints.ofContentType("email"))
        XCTAssertEqual(Hints.organization, Hints.ofContentType("organization"))
        XCTAssertEqual(Hints.cardSecurityCode, Hints.ofContentType("cc-csc"))
        XCTAssertEqual("creditCardNumber", Hints.ofContentType("cc-number"))
        XCTAssertNil(Hints.ofContentType("tel"), "a hint no rule reads")
        let card = FieldInfo(name: nil, label: nil, hints: [Hints.ofContentType("cc-csc")!], value: "123")
        XCTAssertTrue(Forms.withheld(card), "a card's security code by its content type")
    }

    func testANamesWordsSplitAsTheWebSplitsThem() {
        XCTAssertEqual(["card", "cvv"], Forms.nameWords("cardCvv"))
        XCTAssertEqual(["card", "cvv"], Forms.nameWords("CARD_CVV"))
        XCTAssertEqual(["otp", "code"], Forms.nameWords("OTPCode"))
        XCTAssertTrue(Forms.secretName("userPin"))
        XCTAssertFalse(Forms.secretName("deliveryPin"), "a delivery pin is a postcode")
        XCTAssertFalse(Forms.secretName("pinned"))
    }
}
