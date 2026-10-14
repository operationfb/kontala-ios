import Foundation

// What an error a js_error row may carry: its name, its message and its
// source, as tag/plugins/friction/errors.ts reads them and collector/friction
// normalises them again on arrival, the Flutter SDK's friction/messages.dart
// and the Android SDK's Messages.kt. collector/friction/testdata/vectors.json
// holds all of them to one answer. Every pattern is the tag's, which is ES2015
// and means the same in ICU's regular expressions, which NSRegularExpression's
// are: ASCII classes spelled out, and ES2015's word edges spelled out too,
// since ICU's \b is a Unicode word's.

package enum Messages {
    /// The longest message and name a row keeps, in code points.
    package static let maxMessage = 255
    package static let maxName = 64

    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let space = re("[\\t\\n\\u000B\\f\\r ]+")
    private static let edge = re("^ +| +$")
    private static let uncaught = re("^uncaught (?:exception: )?", .caseInsensitive)
    private static let url = re("[A-Za-z][A-Za-z0-9+.-]*://[^\\t\\n\\u000B\\f\\r '\"`<>()]+")
    private static let email = re("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
    private static let uuid = re("[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
    private static let hex = re("(?<![A-Za-z0-9_])[0-9A-Fa-f]{8,}(?![A-Za-z0-9_])")
    private static let digit = re("[0-9]")
    private static let number = re("(?<![A-Za-z0-9_])[0-9]+(?:\\.[0-9]+)?(?![A-Za-z0-9_])")
    private static let quoted = re("(^|[^A-Za-z0-9_])(?:'([^'\\n]*)'|\"([^\"\\n]*)\")")
    private static let ident = Pattern("^[A-Za-z_$][A-Za-z0-9_$]{0,63}$")
    private static let name = Pattern("^[A-Za-z_$][A-Za-z0-9_$.]{0,63}$")
    private static let errorPrefix = re("^((?:[A-Za-z_$][A-Za-z0-9_$.]*)?Error): ")
    private static let trailingSpace = re(" +$")

    /// Whether an error's name is one a row may carry.
    package static func validName(_ n: String) -> Bool { name.matches(n) && n.utf16.count <= maxName }

    /// Text with every run of ASCII whitespace one space, none at either end.
    private static func squash(_ text: String) -> String {
        replacing(edge, in: replacing(space, in: text, with: " "), with: "")
    }

    /// The name a message leads with, `XxxError: `, after any `Uncaught `, or ''.
    package static func nameOf(_ message: String) -> String {
        let m = replacing(uncaught, in: squash(message), with: "", first: true)
        let ns = m as NSString
        guard let found = errorPrefix.firstMatch(in: m, range: NSRange(location: 0, length: ns.length)) else {
            return ""
        }
        let n = ns.substring(with: found.range(at: 1))
        return validName(n) ? n : ""
    }

    /// An error's message as it is kept: collector/friction.NormalizeMessage, whose comment says why.
    package static func normalizeMessage(_ errorName: String, _ message: String) -> String {
        var m = squash(message)
        let prefix = "\(errorName): ".unicodeScalars
        while true {
            let was = m
            m = replacing(uncaught, in: m, with: "", first: true)
            if !errorName.isEmpty && m.unicodeScalars.starts(with: prefix) {
                m = String(String.UnicodeScalarView(m.unicodeScalars.dropFirst(prefix.count)))
            }
            if m == was { break }
        }
        m = replacing(url, in: m, with: "<url>")
        m = replacing(email, in: m, with: "<email>")
        m = replacing(uuid, in: m, with: "<id>")
        m = replacing(hex, in: m) { run, _ in
            let r = run as NSString
            return digit.firstMatch(in: run, range: NSRange(location: 0, length: r.length)) != nil ? "<id>" : run
        }
        m = replacing(number, in: m, with: "<n>")
        m = replacing(quoted, in: m) { whole, groups in
            let single = groups[1]
            let double = groups[2]
            let inner = !(single ?? "").isEmpty ? single! : (double ?? "")
            return ident.matches(inner) ? whole : "\(groups[0] ?? "")'<str>'"
        }
        m = squash(m)
        if m.unicodeScalars.count > maxMessage {
            let cut = String(String.UnicodeScalarView(m.unicodeScalars.prefix(maxMessage)))
            m = replacing(trailingSpace, in: cut, with: "")
        }
        return m
    }

    /// Whether a message is a benign ResizeObserver notice, never a row: a web one, kept so the SDKs read alike.
    package static func ignoredMessage(_ message: String) -> Bool {
        replacing(uncaught, in: squash(message), with: "", first: true).unicodeScalars.starts(
            with: "ResizeObserver loop".unicodeScalars)
    }

    private static let packageSource = Pattern("^package:[a-z][a-z0-9_]{0,63}/[A-Za-z0-9_./-]{1,200}$")
    private static let androidSource = Pattern(
        "^android:[a-z][a-z0-9_]{0,63}(\\.[A-Za-z_][A-Za-z0-9_]{0,63}){0,15}/[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")
    private static let iosSourcePattern = Pattern(
        "^ios:[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}(/[A-Za-z_][A-Za-z0-9_]{0,127})?$")

    /// `collector/friction.AppSource`: the app's own code as a row names it, which is all of a source an app's row
    /// keeps: a Flutter library, `package:shop/cart/cart_page.dart`, an Android frame,
    /// `android:com.example.shop/CartActivity.kt`, or an iOS module, `ios:ShopApp/CartViewController`.
    package static func appSource(_ s: String) -> Bool {
        (packageSource.matches(s) || androidSource.matches(s) || iosSourcePattern.matches(s)) && !s.contains("..")
            && !s.contains("//")
    }

    /// An iOS source: the module the app's code that threw is in, `ios:ShopApp`, and the type, where one is known and
    /// a row may carry it, `ios:ShopApp/CartViewController`; nil where neither may be carried.
    package static func iosSource(module: String, type: String?) -> String? {
        if let t = type, !t.isEmpty, appSource("ios:\(module)/\(t)") { return "ios:\(module)/\(t)" }
        return appSource("ios:\(module)") ? "ios:\(module)" : nil
    }

    /// The module and the type a symbol of the app's names, where it says: a Swift symbol, `$s7ShopApp18Cart...C3payyyF`,
    /// read as far as its module and the first type in it, and an Objective-C method, `-[CartViewController pay:]`,
    /// whose class is its type and which names no module. Nothing is demangled past what is literal: a type whose name
    /// the mangling abbreviates is no type.
    package static func symbolParts(_ symbol: String) -> (module: String?, type: String?)? {
        if let open = symbol.firstIndex(of: "["), symbol.first == "-" || symbol.first == "+",
            let space = symbol[open...].firstIndex(of: " ")
        {
            var type = String(symbol[symbol.index(after: open)..<space])
            // A category's methods name their class with the category in brackets.
            if let paren = type.firstIndex(of: "(") { type = String(type[..<paren]) }
            return (nil, type.isEmpty ? nil : type)
        }
        var s = Substring(symbol)
        if s.hasPrefix("_") { s = s.dropFirst() }
        guard s.hasPrefix("$s") || s.hasPrefix("$S") else { return nil }
        s = s.dropFirst(2)
        guard let module = identifier(&s) else { return nil }
        // A type's name follows its module, marked as a class, a struct or an enum; a global function's name
        // follows it too, and is no type.
        guard let type = identifier(&s), let kind = s.first, "CVO".contains(kind) else { return (module, nil) }
        return (module, type)
    }

    /// A frame of a native stack as the platform read it: the image it is in, by its path, the symbol it is in where
    /// the image names one, and how far into that symbol it is, in bytes.
    package struct NativeFrame {
        package var image: String
        package var symbol: String?
        package var offset: Int?

        package init(image: String, symbol: String? = nil, offset: Int? = nil) {
            self.image = image
            self.symbol = symbol
            self.offset = offset
        }
    }

    /// Where an exception came from: the SDK's own code, which is never a row, or the app's, named by its source
    /// where it may be.
    package enum Origin: Equatable {
        case sdk
        case app(String?)
    }

    /// The modules this SDK's code is in, statically linked into an app or a framework of their own.
    private static let sdkModules: Set<String> = ["Kontala", "KontalaCore"]

    /// How far into a symbol a frame may be and still be in it: a stripped build names only the symbols it exports,
    /// and the nearest one before a frame can be another function's, far away.
    private static let symbolReach = 65_536

    /// Where an iOS exception came from, read off its stack, the Android SDK's `appFrame` and `sdkStack` for a
    /// platform whose stacks begin in the exception machinery and keep no file names: the frame that raised it, past
    /// that machinery, is the SDK's where it is in the SDK's modules, and then it is no row; otherwise its source is
    /// the first frame in the app's bundle ([appRoot]) that is neither the SDK's nor the app's entry point, every stack
    /// holding one, named by its module, and by its type where its symbol says one.
    package static func iosOrigin(_ frames: [NativeFrame], appRoot: String) -> Origin {
        let root = unprivate(appRoot) + "/"
        var raiser = true
        for f in frames.prefix(64) {
            if raising(f) { continue }
            let own = unprivate(f.image).hasPrefix(root)
            let near = f.offset.map { $0 >= 0 && $0 < symbolReach } ?? false
            let parts = near ? f.symbol.flatMap(symbolParts) : nil
            let module = parts?.module ?? (f.image as NSString).lastPathComponent
            let sdk = own && sdkModules.contains(module)
            if raiser {
                raiser = false
                if sdk { return .sdk }
            }
            if !own || sdk || entry(f.symbol) { continue }
            return .app(iosSource(module: module, type: parts?.type))
        }
        return .app(nil)
    }

    /// Whether a frame is Objective-C's exception machinery, which raises whatever is thrown.
    private static func raising(_ f: NativeFrame) -> Bool {
        if f.image.hasSuffix("/libobjc.A.dylib") { return true }
        guard let s = f.symbol else { return false }
        return s == "__exceptionPreprocess" || s == "objc_exception_throw" || s == "objc_exception_rethrow"
            || s.hasPrefix("-[NSException raise") || s.hasPrefix("+[NSException raise")
    }

    /// Whether a frame is the app's entry point, which every stack of its main thread holds.
    private static func entry(_ symbol: String?) -> Bool {
        guard let s = symbol else { return false }
        return s == "main" || s.contains("$main")
    }

    /// A path as the kernel and the bundle name it alike: `/var` is `/private/var`.
    private static func unprivate(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    /// A literal identifier of a Swift mangling, its length then its characters; nil for anything else, a
    /// substitution or a word substitution among them.
    private static func identifier(_ s: inout Substring) -> String? {
        var digits = ""
        while let c = s.first, c.isASCII, c.isNumber {
            digits.append(c)
            s = s.dropFirst()
        }
        guard let n = Int(digits), n > 0, digits.first != "0", s.count >= n else { return nil }
        let id = String(s.prefix(n))
        s = s.dropFirst(n)
        return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } ? id : nil
    }

    // Replacing with NSRegularExpression, by the UTF-16 offsets it works in.

    private static func replacing(
        _ re: NSRegularExpression, in s: String, with literal: String, first: Bool = false
    ) -> String {
        replacing(re, in: s, first: first) { _, _ in literal }
    }

    /// [s] with each match of [re], or the first, replaced by what [f] answers for the match and its groups after the
    /// whole, each nil where it took no part.
    private static func replacing(
        _ re: NSRegularExpression, in s: String, first: Bool = false, _ f: (String, [String?]) -> String
    ) -> String {
        let ns = s as NSString
        var matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return s }
        if first { matches = [matches[0]] }
        var out = ""
        var last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var groups: [String?] = []
            if m.numberOfRanges > 1 {
                for i in 1..<m.numberOfRanges {
                    let r = m.range(at: i)
                    groups.append(r.location == NSNotFound ? nil : ns.substring(with: r))
                }
            }
            out += f(ns.substring(with: m.range), groups)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
