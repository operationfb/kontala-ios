/// How far down each screen view its visitor got, as a `scroll_depth` row filed under its view, by the tag's rules and
/// the Flutter SDK's (scroll/scroll.dart): sent when the view ends (`view`) and as the app is hidden (`hide`), and again
/// only deeper, so the warehouse takes each view's latest.
///
/// The platform reads the screen's scroll view on the main thread, where it is, through a throttle, once the view
/// settles and as the app is hidden, and tells each [Reading] here; one taken from a navigation's start until its view
/// opens is dropped, since a screen scrolls back to its top as it goes.
package final class ScrollPlugin: KontalaPlugin {
    package let key = "scroll"

    private weak var ctx: PluginContext?
    private var view: CapturedEvent?
    private var depth = Depth()
    private var sent: Measured?
    private var frozen = false

    package init() {}

    package func bind(_ context: PluginContext) {
        ctx = context
        context.onViewStart { [weak self] in self?.started($0) }
        context.onViewEnd { [weak self] in self?.send($0, "view") }
        context.onNavigationStart { [weak self] _ in self?.frozen = true }
        context.onNavigationIdle { [weak self] in self?.frozen = false }
        context.onHide { [weak self] in
            guard let self = self, let v = self.view else { return }
            self.send(v, "hide")
        }
    }

    private var rules: ScrollRules? {
        guard let ctx = ctx, ctx.options.scroll, ctx.captures(.scroll) else { return nil }
        return ctx.served.scroll
    }

    private func started(_ v: CapturedEvent) {
        view = v
        depth = Depth()
        sent = nil
        frozen = false
    }

    /// A reading of the screen's scroll view, in points.
    package func read(_ r: Reading) {
        if frozen || view == nil || rules == nil { return }
        depth.record(r)
    }

    private func send(_ v: CapturedEvent, _ trigger: String) {
        guard let ctx = ctx, v === view, rules != nil, let now = depth.measure(), deeper(now, sent) else { return }
        sent = now
        ctx.emit(
            "scroll_depth",
            [
                "scroll": [
                    "trigger": .string(trigger),
                    "depth_px": .int(now.depthPx),
                    "height_px": .int(now.heightPx),
                    "viewport_px": .int(now.viewportPx),
                    "root": "element",
                ]
            ],
            viewOf: v.id,
            measure: true)
    }
}
