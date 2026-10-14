/// A return to the app within its visit, the app's counterpart of a page the back/forward cache restores: a
/// `page_restore` row with how long the app was away and which of the launch's returns it is, filed under the view it
/// came back to. A return after the visit lapsed opens the screen again as a new visit's entrance instead.
package final class RestoresPlugin: KontalaPlugin {
    package let key = "restores"

    private weak var ctx: PluginContext?
    private var restores = 0

    package init() {}

    package func bind(_ context: PluginContext) {
        ctx = context
        context.onShow { [weak self] away, reopened in self?.shown(away, reopened) }
    }

    private func shown(_ awayMicros: Int64, _ reopened: Bool) {
        guard let ctx = ctx, !reopened, ctx.options.friction, ctx.captures(.friction),
            let rules = ctx.served.friction
        else { return }
        if restores >= rules.restoresPerPage || ctx.currentView == nil { return }
        restores += 1
        ctx.emit("page_restore", ["restore": ["away_ms": .int(awayMicros / 1000), "restores": .int(Int64(restores))]])
    }
}
