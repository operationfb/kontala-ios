import Foundation

// What a form sent and who a login names, the Flutter SDK's forms.dart rules
// over a field as any toolkit describes it: a UIKit text field, and a SwiftUI
// one, which is a UIKit text field underneath, are each read into a
// [FieldInfo] by the platform, and every rule here is the same for both. The
// web's rules (tag/plugins/clicks/element.ts and policy.ts) are the source,
// and the collector applies the secret names again on arrival
// (`clicks.SecretName`, held to the same vectors).

/// The autofill hints the rules read, in the Flutter SDK's names, to which iOS's text content types are read.
package enum Hints {
    package static let username = "username"
    package static let password = "password"
    package static let newPassword = "newPassword"
    package static let oneTimeCode = "oneTimeCode"
    package static let email = "email"
    package static let organization = "organizationName"
    package static let cardSecurityCode = "creditCardSecurityCode"
    package static let cardPrefix = "creditCard"

    /// A text content type as UIKit names it (`UITextContentType`'s raw value, the web's autocomplete token) in the
    /// Flutter SDK's name for it, or nil for one the rules never read.
    package static func ofContentType(_ type: String) -> String? {
        switch type {
        case "username": return username
        case "password": return password
        case "new-password": return newPassword
        case "one-time-code": return oneTimeCode
        case "email": return email
        case "organization": return organization
        case "cc-csc": return cardSecurityCode
        case "cc-number": return "creditCardNumber"
        case "cc-exp": return "creditCardExpirationDate"
        case "cc-exp-month": return "creditCardExpirationMonth"
        case "cc-exp-year": return "creditCardExpirationYear"
        case "cc-name": return "creditCardName"
        case "cc-given-name": return "creditCardGivenName"
        case "cc-additional-name": return "creditCardMiddleName"
        case "cc-family-name": return "creditCardFamilyName"
        case "cc-type": return "creditCardType"
        default: return nil
        }
    }
}

/// A text field inside a form, as the web's `form.fields` reads one.
package struct FieldInfo {
    /// What names it: its accessibility identifier, or its content type's name.
    package var name: String?
    /// The label it shows: its placeholder, or an accessibility label the app gave it.
    package var label: String?
    package var hints: [String] = []
    /// A field that hides its text.
    package var obscured = false
    package var multiline = false
    /// A field whose keyboard is for an email address.
    package var email = false
    /// A search box: a search field, a search bar's, a search key, or a label saying search.
    package var search = false
    /// What the visitor typed.
    package var value = ""

    package init(
        name: String?, label: String?, hints: [String] = [], obscured: Bool = false, multiline: Bool = false,
        email: Bool = false, search: Bool = false, value: String = ""
    ) {
        self.name = name
        self.label = label
        self.hints = hints
        self.obscured = obscured
        self.multiline = multiline
        self.email = email
        self.search = search
        self.value = value
    }

    package func hinted(_ hint: String) -> Bool { hints.contains(hint) }
}

package enum Forms {
    /// How many of a form's values are sent, and the longest name and value.
    package static let maxValues = 64
    package static let maxValueName = 128
    package static let maxValue = 500

    private static let secretWords: Set<String> = [
        "password", "passwd", "pwd", "passcode", "cvv", "cvv2", "cvc", "cvc2", "csc", "otp", "csrf", "xsrf",
        "authenticity",
    ]

    private static let postalWords: Set<String> = ["address", "delivery", "shipping", "location", "postal"]

    private static let secretHints: Set<String> = [
        Hints.password, Hints.newPassword, Hints.oneTimeCode, Hints.cardSecurityCode,
    ]

    private static let camel = try! NSRegularExpression(pattern: "([a-z0-9])([A-Z])")
    private static let acronym = try! NSRegularExpression(pattern: "([A-Z]+)([A-Z][a-z])")
    private static let separators = try! NSRegularExpression(pattern: "[^a-z0-9]+")

    private static func replacing(_ re: NSRegularExpression, _ s: String, _ template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s), withTemplate: template)
    }

    /// The words a field's name splits into: on anything but a letter or a digit, and between a lower case letter or
    /// digit and an upper case one, so `cardCvv`, `card-cvv` and `CARD_CVV` all read as card and cvv.
    package static func nameWords(_ name: String) -> [String] {
        let split = replacing(acronym, replacing(camel, name, "$1 $2"), "$1 $2").lowercased()
        return replacing(separators, split, " ").split(separator: " ").map(String.init)
    }

    /// Whether a field's name says it holds a value no one may keep: a password, a card's security code, a one-time
    /// code, a PIN or an anti-forgery token, by whole words, so `pinned` is no PIN and a delivery pin is a postcode.
    package static func secretName(_ name: String) -> Bool {
        let words = nameWords(name)
        if words.contains(where: { secretWords.contains($0) }) { return true }
        return words.contains("pin") && !words.contains(where: { postalWords.contains($0) })
    }

    /// Whether a value's name may be sent: 1 to 128 code points, none a control.
    package static func valueName(_ name: String) -> Bool {
        let n = codePointCount(name)
        if n == 0 || n > maxValueName { return false }
        return name.unicodeScalars.allSatisfy { u in
            let r = u.value
            return !(r < 0x20 || (0x7F..<0xA0).contains(r))
        }
    }

    /// Whether a text field's value is withheld: one that hides its text, a secret's hint, or a name that says it is a
    /// secret.
    package static func withheld(_ f: FieldInfo) -> Bool {
        f.obscured || f.hints.contains(where: { secretHints.contains($0) }) || (f.name.map(secretName) ?? false)
    }

    /// What a form holds, by kind, as the web's `form.fields` says it, sorted.
    package static func fieldKinds(_ fields: [FieldInfo]) -> [String] {
        var kinds = Set<String>()
        for f in fields {
            if f.multiline { kinds.insert("message") }
            if f.obscured { kinds.insert("password") }
            if f.hinted(Hints.newPassword) { kinds.insert("new_password") }
            if f.hints.contains(where: { $0.hasPrefix(Hints.cardPrefix) }) { kinds.insert("card") }
            if f.search { kinds.insert("search") }
            if f.email || f.hinted(Hints.email) { kinds.insert("email") }
        }
        return kinds.sorted()
    }

    private static let userWords = try! NSRegularExpression(
        pattern: "user|login|e-?mail|customer|account", options: [.caseInsensitive])
    private static let orgWords = try! NSRegularExpression(
        pattern: "\\borg|organi[sz]ation|company|tenant|workspace", options: [.caseInsensitive])

    private static func contains(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)) != nil
    }

    /// Who a login names: the username and the organisation typed into its form, by the owner's decision of 2026-10-02
    /// for the web. A login is a form holding a field that hides its text, or one whose hints say password or username,
    /// so the first step of a two-step login counts and a sign-up names who signs up; or a tap declared `login` or
    /// `sign_up` ([declared]). Each half is named only when it is a valid principal id.
    package static func loginIn(_ fields: [FieldInfo], declared: Bool = false) -> (user: String?, org: String?)? {
        if fields.isEmpty { return nil }
        let login =
            declared
            || fields.contains {
                $0.obscured || $0.hinted(Hints.password) || $0.hinted(Hints.newPassword) || $0.hinted(Hints.username)
            }
        if !login { return nil }
        func says(_ f: FieldInfo, _ words: NSRegularExpression) -> Bool {
            (f.name.map { contains(words, $0) } ?? false) || (f.label.map { contains(words, $0) } ?? false)
        }
        let text = fields.enumerated().filter { !$0.element.obscured }
        var user =
            text.first { $0.element.hinted(Hints.username) }
            ?? text.first { $0.element.hinted(Hints.email) }
            ?? text.first { $0.element.email }
            ?? text.first { says($0.element, userWords) && !says($0.element, orgWords) }
        let org = text.first { e in
            e.offset != user?.offset && (e.element.hinted(Hints.organization) || says(e.element, orgWords))
        }
        if user == nil {
            let left = text.filter { $0.offset != org?.offset }
            if left.count == 1 { user = left[0] }
        }
        func valid(_ f: FieldInfo?) -> String? {
            guard let v = f?.value.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            return Ids.safePrincipalId.matches(v) ? v : nil
        }
        let u = valid(user?.element)
        let o = valid(org?.element)
        if u == nil && o == nil { return nil }
        return (u, o)
    }

    /// A label as a name: `E-mail address` as `e_mail_address`.
    package static func snake(_ label: String?) -> String? {
        guard let label = label else { return nil }
        let s = replacing(separators, label.lowercased(), "_").trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return s.isEmpty ? nil : s
    }

    /// A field's first hint that is no secret's, as its name.
    package static func hintName(_ f: FieldInfo) -> String? { f.hints.first { !secretHints.contains($0) } }

    /// A choice's value as a form sends it: a state as `true` or `false`, a whole number without its point.
    package static func text(_ v: Any?) -> String? {
        guard let v = v else { return nil }
        switch v {
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        case let i as Int64: return String(i)
        case let i as Int32: return String(i)
        case let d as Double:
            return d.isFinite && d == d.rounded() && abs(d) < 9.2e18 ? String(Int64(d)) : String(d)
        case let f as Float: return text(Double(String(f)))
        case let s as String: return s
        default:
            return Mirror(reflecting: v).displayStyle == .enum ? String(describing: v) : nil
        }
    }

    /// One of a form's values, in the order the form holds it: a text field's, or a choice's under its name.
    package enum Entry {
        case text(FieldInfo)
        case choice(name: String?, value: String?)
    }

    /// What a form holds, name by name, as the visitor entered it: each text field's text and each choice's value,
    /// several under one name joined with `|`, at most [maxValues] names and [maxValue] code points each, a field with
    /// no name of its own named by its place (`field_<n>`). A secret is never read.
    package static func values(_ entries: [Entry]) -> JSONObject {
        var names: [String] = []
        var values: [String: [String]] = [:]
        var n = 0
        func add(_ name: String?, _ value: String?) {
            n += 1
            guard let value = value else { return }
            let key = name ?? "field_\(n)"
            if !valueName(key) || secretName(key) { return }
            if values[key] == nil {
                if names.count >= maxValues { return }
                names.append(key)
            }
            values[key, default: []].append(value)
        }
        for e in entries {
            switch e {
            case .text(let f):
                if withheld(f) {
                    n += 1
                    continue
                }
                add(f.name ?? hintName(f) ?? snake(f.label), f.value)
            case .choice(let name, let value):
                add(name, value)
            }
        }
        var out = JSONObject()
        for k in names { out[k] = .string(cutRunes(values[k]!.joined(separator: "|"), maxValue)) }
        return out
    }

    /// A search box's term: collapsed, never a withheld field's.
    package static func term(_ f: FieldInfo) -> String? {
        if withheld(f) { return nil }
        let t = collapse(f.value, Limits.maxText)
        return t.isEmpty ? nil : t
    }
}
