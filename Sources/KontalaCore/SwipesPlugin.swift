/// The effects an app's swipe may have, every one of the web's but `page`, since an app's screen scrolls in a scroll
/// view.
package let appEffects = ["scrolled", "script", "none"]

/// Whether a swipe in [direction] with [effect] is one an app sends: `collector/scroll.Captured`, which the vectors hold
/// this to. A vertical swipe that scrolled is scrolling, which depth measures, so it is sent only when the app's own
/// code took it.
package func swipeCaptured(_ direction: String, _ effect: String) -> Bool {
    if !appEffects.contains(effect) { return false }
    if direction == "left" || direction == "right" { return true }
    return (direction == "up" || direction == "down") && effect == "script"
}

/// A swipe as the platform read it, by the tag's rules and the thresholds the property is served: which way, what it
/// did, how far in points and how long, what it was on, described without its text, and where it began.
package struct Swipe {
    package var direction: String
    package var effect: String
    package var distance: Int64
    package var durationMs: Int64
    package var target: TapTarget
    package var x: Double
    package var y: Double

    package init(
        direction: String, effect: String, distance: Int64, durationMs: Int64, target: TapTarget, x: Double, y: Double
    ) {
        self.direction = direction
        self.effect = effect
        self.distance = distance
        self.durationMs = durationMs
        self.target = target
        self.x = x
        self.y = y
    }
}

/// Swipes, as `swipe` rows, the Flutter SDK's (scroll/swipes.dart): the platform tells each swipe it read off the
/// touches of a finger, and this sends those the property captures, at most the served number a view and a launch.
package final class SwipesPlugin: KontalaPlugin {
    package let key = "swipes"

    private weak var ctx: PluginContext?
    private var inView = 0
    private var inLaunch = 0

    package init() {}

    package func bind(_ context: PluginContext) {
        ctx = context
        context.onViewStart { [weak self] _ in self?.inView = 0 }
    }

    private var rules: SwipeRules? {
        guard let ctx = ctx, ctx.options.scroll, ctx.captures(.scroll) else { return nil }
        return ctx.served.scroll?.swipes
    }

    package func swiped(_ s: Swipe) {
        guard let ctx = ctx, let r = rules, swipeCaptured(s.direction, s.effect) else { return }
        if inView >= r.perView || inLaunch >= r.perPage { return }
        inView += 1
        inLaunch += 1
        var fields: JSONObject = [
            "swipe": [
                "direction": .string(s.direction),
                "effect": .string(s.effect),
                "distance": .int(s.distance),
                "duration_ms": .int(s.durationMs),
            ]
        ]
        // What a swipe was on never says what it shows, since a carousel's text is every slide's.
        var described = s.target
        described.text = nil
        described.declared = nil
        for (k, v) in described.toFields() { fields[k] = v }
        fields["x"] = .double(coordinate(s.x))
        fields["y"] = .double(coordinate(s.y))
        ctx.emit("swipe", fields)
    }
}
