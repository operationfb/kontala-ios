/// The kinds that leave only on a grant, as the tag's `grantOnly` list says: what they carry could not be taken back by
/// a redaction on arrival.
package let grantOnlyKinds: Set<String> = [
    "click",
    "swipe",
    "scroll_depth",
    "page_speed",
    "js_error",
    "rage_click",
    "dead_click",
    "page_restore",
    "view_time",
    "page_type",
    "consent_change",
]

/// Holds events while consent is `unknown`, as tag/core/core.consent.ts's gate does, and releases them stamped with
/// the answer and one identity shared by the whole buffer: the first answer, going to the background, a full buffer or
/// the hold timeout, whichever comes first.
///
/// `release` passes events on: one at a time as they come while consent is answered, or the held ones as one batch,
/// `held` true, which then share one identity resolved at release.
package final class ConsentGate {
    package private(set) var state: KontalaConsent
    private let holdMicros: Int64
    private let maxHeld: Int
    private let scheduler: Scheduler
    private let release: ([CapturedEvent], KontalaConsent, Bool) -> Void

    private var held: [CapturedEvent] = []
    private var timer: Cancellable?

    package init(
        initial: KontalaConsent, holdMicros: Int64, maxHeld: Int, scheduler: Scheduler,
        release: @escaping ([CapturedEvent], KontalaConsent, Bool) -> Void
    ) {
        state = initial
        self.holdMicros = holdMicros
        self.maxHeld = maxHeld
        self.scheduler = scheduler
        self.release = release
    }

    /// Passes an event on, or holds it while consent is unknown.
    package func offer(_ event: CapturedEvent) {
        if state != .unknown {
            release([event], state, false)
            return
        }
        held.append(event)
        if timer == nil {
            timer = scheduler.schedule(holdMicros) { [weak self] in self?.flush(.unknown) }
        }
        if held.count >= maxHeld { flush(.unknown) }
    }

    /// The visitor's answer. Held events are released with it.
    package func set(_ state: KontalaConsent) {
        self.state = state
        if state != .unknown { flush(state) }
    }

    /// The app went to the background: held events leave as unknown, since an app may never come back.
    package func onHidden() { flush(.unknown) }

    private func flush(_ stamp: KontalaConsent) {
        timer?.cancel()
        timer = nil
        if held.isEmpty { return }
        let batch = held
        held.removeAll()
        release(batch, stamp, true)
    }

    /// Drops every held event, for an opt-out.
    package func clear() { held.removeAll() }

    /// Drops one held event, a screen view withdrawn as a container of web pages. Answers whether it was held.
    package func withdraw(_ eventId: String) -> Bool {
        let before = held.count
        held.removeAll { $0.id == eventId }
        return held.count != before
    }

    package func dispose() {
        timer?.cancel()
        timer = nil
    }
}
