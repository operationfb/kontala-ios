import Foundation

/// What a tap acted on, described as the Events API's click reads it (`element`, `path`, `region`, `click_type`), under
/// the web's click policy: a field never sends its text, a choice never its id, label or text, and a masked control only
/// its role. A toolkit's resolver builds it from what it reads of the control; the Flutter SDK's `TapTarget`.
package struct TapTarget: Equatable {
    /// button, link, tab, menuitem, checkbox, radio, switch, option, textbox, searchbox, image, cell or other.
    package var role: String
    /// A control the app disabled, which no enabled control around it handled.
    package var disabled = false
    package var masked = false
    package var declared: KontalaClickType?
    package var id: String?
    package var label: String?
    package var text: String?
    package var link: String?
    package var className: String?
    package var path: String?
    package var region: String?

    package init(
        role: String, disabled: Bool = false, masked: Bool = false, declared: KontalaClickType? = nil,
        id: String? = nil, label: String? = nil, text: String? = nil, link: String? = nil, className: String? = nil,
        path: String? = nil, region: String? = nil
    ) {
        self.role = role
        self.disabled = disabled
        self.masked = masked
        self.declared = declared
        self.id = id
        self.label = label
        self.text = text
        self.link = link
        self.className = className
        self.path = path
        self.region = region
    }

    package var isField: Bool { role == "textbox" || role == "searchbox" }

    package var isChoice: Bool { role == "checkbox" || role == "radio" || role == "switch" || role == "option" }

    /// The click's `element`, `path`, `region` and `click_type`.
    package func toFields() -> JSONObject {
        var element = JSONObject()
        element["role"] = .string(role)
        if let v = id { element["id"] = .string(v) }
        if let v = label { element["label"] = .string(v) }
        if let v = text { element["text"] = .string(v) }
        if let v = link { element["link"] = .string(v) }
        if let v = className { element["class"] = .string(v) }
        var out = JSONObject()
        out["element"] = .object(element)
        if let v = path { out["path"] = .string(v) }
        if let v = region { out["region"] = .string(v) }
        if let v = declared { out["click_type"] = .string(v.wire) }
        return out
    }
}

/// A tap as the platform read it, at its press, while what the visitor pressed was still on show: what it acted on, the
/// control as an identity a second tap is compared by, where and how, who a login names, and from contract 2 what a
/// submit button sent.
package final class Press {
    package let target: TapTarget
    /// A view's [RouteRef], held weakly, or an object naming a control of another toolkit's, a SwiftUI marker's.
    package let control: AnyObject?
    package let input: String
    /// Where, in points from the window's corner, to a tenth; none for a keyboard.
    package let x: Double?
    package let y: Double?
    package let namedUser: String?
    package let namedOrg: String?
    /// From contract 2: `trigger`, `form` and `search`.
    package let submits: JSONObject

    package init(
        _ target: TapTarget, control: AnyObject?, input: String, x: Double? = nil, y: Double? = nil,
        namedUser: String? = nil, namedOrg: String? = nil, submits: JSONObject = JSONObject()
    ) {
        self.target = target
        self.control = control
        self.input = input
        self.x = x
        self.y = y
        self.namedUser = namedUser
        self.namedOrg = namedOrg
        self.submits = submits
    }
}

/// A position in points, from 0, to a tenth, as the Flutter SDK rounds a logical pixel.
package func coordinate(_ v: Double) -> Double {
    v.isFinite && v > 0 ? (v * 10).rounded(.toNearestOrEven) / 10 : 0
}

/// Taps, pointer clicks and keyboard activations, each a `click` row naming the control it acted on, as the tag's click
/// plugin names an element; and a field's form sent from the keyboard, a `submit` row naming the field. The platform's
/// resolver reads every one; this decides which are sent: one control's repeated tap within [dedupeMicros] is one, a
/// double tap's or a label's forwarded click.
package final class TapsPlugin: KontalaPlugin {
    package let key = "taps"

    /// The tag's window for one control's repeated click: a double tap, or a click a label forwards.
    package static let dedupeMicros: Int64 = 500_000

    private weak var ctx: PluginContext?
    private var lastControl: AnyObject?
    private var lastAt: Int64?

    package init() {}

    package func bind(_ context: PluginContext) {
        ctx = context
    }

    /// Whether taps are captured: the app's switch and the property's.
    package var on: Bool {
        guard let ctx = ctx else { return false }
        return ctx.options.taps && ctx.captures(.clicks)
    }

    package func tapped(_ p: Press) {
        guard let ctx = ctx, on, !p.target.disabled else { return }
        let now = ctx.nowMicros()
        if same(lastControl, p.control), let last = lastAt, now - last < TapsPlugin.dedupeMicros { return }
        lastControl = p.control
        lastAt = now
        var fields = p.target.toFields()
        fields["input"] = .string(p.input)
        if let x = p.x { fields["x"] = .double(coordinate(x)) }
        if let y = p.y { fields["y"] = .double(coordinate(y)) }
        for k in p.submits.keys { fields[k] = p.submits[k] }
        ctx.emit("click", fields, namedUser: p.namedUser, namedOrg: p.namedOrg)
    }

    private func same(_ a: AnyObject?, _ b: AnyObject?) -> Bool {
        guard let a = a, let b = b else { return false }
        if let x = a as? RouteRef, let y = b as? RouteRef { return x.same(y) }
        return a === b
    }
}
