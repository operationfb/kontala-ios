/// The names Kontala gives its own events (collector/internal/api/build.go `reserved`), which a custom event may not
/// take in any case or spelling.
package let reservedEventNames: Set<String> = [
    "scroll_depth",
    "swipe",
    "page_speed",
    "js_error",
    "rage_click",
    "dead_click",
    "page_restore",
    "data_layer_snapshot",
    "data_layer_event",
    "page_signals",
    "page_type",
    "shopify_page_viewed",
    "shopify_pixel",
    "cart_viewed",
    "cart_add",
    "cart_remove",
    "checkout_started",
    "checkout_step",
    "purchase",
    "checkout_alert",
    "checkout_extension_error",
    "page_view",
    "click",
    "view_time",
]

/// Whether [u] is a letter or a number, as `\p{L}` and `\p{N}` read one.
private func isWord(_ u: Unicode.Scalar) -> Bool {
    switch u.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
        .decimalNumber, .letterNumber, .otherNumber:
        return true
    default:
        return false
    }
}

/// A name as the reserved names are written: lower case, every run of anything but a letter or a digit one `_` (the
/// API's `canonical`).
package func canonicalEventName(_ name: String) -> String {
    var b = String.UnicodeScalarView()
    var gap = false
    for u in name.lowercased().unicodeScalars {
        if isWord(u) {
            if gap && !b.isEmpty { b.append("_") }
            b.append(u)
            gap = false
        } else {
            gap = true
        }
    }
    return String(b)
}
