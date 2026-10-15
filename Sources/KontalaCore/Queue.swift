import Foundation

/// Holds captured events until they are sealed into a request.
///
/// An event is appended to `queue/current.jsonl` as it is captured (written at most every 250 ms, and at once on
/// hide), so an app killed before a flush loses nothing. A batch is sealed when one of these comes first: `maxEvents`,
/// `maxBytes`, `intervalMicros` after its first event, the app going to the background, or `flush`. A sealed batch is
/// written as `queue/sealed/<id>.json` before it is sent and deleted once its outcome is final, and on launch sealed
/// batches are sent first.
///
/// A page view is held back from sealing until its view has settled (`settleMicros`, the tag's `settle_ms`), so
/// properties and a page type declared just after the screen opened still ride on it.
package final class EventQueue {
    package static let current = "queue/current.jsonl"

    /// Where a crash's row waits for the next launch, which the queue reads as it restores.
    package static let crash = "queue/crash.jsonl"

    private let store: FileStore
    private let encoder: WireEncoder
    private let sender: Sender
    private let clock: Clock
    private let scheduler: Scheduler
    private let maxEvents: Int
    private let maxBytes: Int
    private let intervalMicros: Int64
    private let settleMicros: Int64
    private let maxQueuedEvents: Int
    private let maxQueuedBytes: Int
    /// The API refuses a timestamp more than 30 days old, so an event a day short of that is dropped rather than sent
    /// to be refused.
    private let maxAgeMicros: Int64
    private let log: ((String) -> Void)?

    private var pendingEvents: [CapturedEvent] = []
    private var pendingBytes = 0
    private var sealTimer: Cancellable?
    private var writeTimer: Cancellable?

    package init(
        store: FileStore, encoder: WireEncoder, sender: Sender, clock: Clock, scheduler: Scheduler,
        maxEvents: Int = 50, maxBytes: Int = 512 * 1024, intervalMicros: Int64 = 15_000_000,
        settleMicros: Int64 = 1_000_000, maxQueuedEvents: Int = 10_000, maxQueuedBytes: Int = 5 * 1024 * 1024,
        maxAgeMicros: Int64 = 29 * 24 * 3600 * 1_000_000, log: ((String) -> Void)? = nil
    ) {
        self.store = store
        self.encoder = encoder
        self.sender = sender
        self.clock = clock
        self.scheduler = scheduler
        self.maxEvents = maxEvents
        self.maxBytes = maxBytes
        self.intervalMicros = intervalMicros
        self.settleMicros = settleMicros
        self.maxQueuedEvents = maxQueuedEvents
        self.maxQueuedBytes = maxQueuedBytes
        self.maxAgeMicros = maxAgeMicros
        self.log = log
    }

    package var pending: [CapturedEvent] { pendingEvents }

    /// Reads what an earlier process left: sealed batches are sent first, then the events it had not sealed.
    package func restore() {
        guard let dir = store.directory() else { return }
        let sealed = dir.appendingPathComponent("queue/sealed")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: sealed.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()
        for f in names {
            let name = "queue/sealed/\(f)"
            guard let body = store.readJson(name), let events = body.list("events"), !events.isEmpty else {
                store.delete(name)
                continue
            }
            sender.enqueue(SealedBatch(String(f.dropLast(".json".count)), body, events.count))
        }
        readLines(EventQueue.current)
        // A crash's row, which the thread that crashed wrote beside the queue, is the last thing that process did.
        if readLines(EventQueue.crash) {
            store.delete(EventQueue.crash)
            writeNow()
        }
        pendingBytes = pendingEvents.reduce(0) { $0 + $1.encodedLength }
        if !pendingEvents.isEmpty { schedule() }
    }

    /// Reads one file of stored events, one to a line; answers whether it was there.
    @discardableResult
    private func readLines(_ name: String) -> Bool {
        guard store.exists(name), let text = store.readString(name) else { return false }
        for line in text.split(separator: "\n") {
            if line.allSatisfy({ $0.isWhitespace }) { continue }
            // A line cut short by a killed process is that event alone, and so is a line that is JSON but no event.
            guard let m = Json.decodeObject(String(line)), let e = try? CapturedEvent.fromStored(m) else { continue }
            pendingEvents.append(e)
        }
        return true
    }

    package func add(_ event: CapturedEvent) {
        pendingEvents.append(event)
        pendingBytes += event.encodedLength
        enforceCaps()
        scheduleWrite()
        if pendingEvents.count >= maxEvents || pendingBytes >= maxBytes { seal() } else { schedule() }
    }

    /// Rewrites the unsent events on disk after one of them changed: a page view given a page type or properties just
    /// after its screen opened.
    package func touched() { scheduleWrite() }

    /// Takes back an unsealed event: a screen view withdrawn as a container of web pages, whose page views are the
    /// page's. Answers whether it was waiting here.
    package func withdraw(_ event: CapturedEvent) -> Bool {
        guard !event.sealed, let i = pendingEvents.firstIndex(where: { $0 === event }) else { return false }
        pendingEvents.remove(at: i)
        pendingBytes -= event.encodedLength
        scheduleWrite()
        return true
    }

    /// Writes the unsent events now, as the app becomes inactive; while consent is not granted, it deletes them from
    /// disk instead.
    package func save() { writeNow() }

    /// Seals what is waiting into requests and hands them to the sender. [force] seals a page view that has not
    /// settled yet.
    package func seal(force: Bool = false) {
        sealTimer?.cancel()
        sealTimer = nil
        if pendingEvents.isEmpty { return }
        if !force {
            let wait = settleWait()
            if wait > 0 {
                sealTimer = scheduler.schedule(wait) { [weak self] in self?.seal() }
                return
            }
        }
        let now = clock.nowMicros()
        pendingEvents.removeAll { e in
            let old = now - e.atMicros > maxAgeMicros
            if old { log?("an event from \(e.atMicros) was older than the API takes, and was dropped") }
            return old
        }
        while !pendingEvents.isEmpty {
            var take: [CapturedEvent] = []
            var bytes = 0
            for e in pendingEvents {
                let n = e.encodedLength
                if !take.isEmpty && (take.count >= maxEvents || bytes + n > maxBytes) { break }
                take.append(e)
                bytes += n
            }
            pendingEvents.removeFirst(take.count)
            for e in take { e.sealed = true }
            guard let body = encoder.encodeBatch(take) else {
                // Every event of it was one its region's collector does not read.
                log?("\(take.count) events of a later contract than the collector reads were not sent")
                continue
            }
            let written = body.list("events")?.count ?? 0
            let batch = SealedBatch(Ids.uuidV7(clock.nowMillis()), body, written)
            store.writeJson(batch.fileName, body)
            sender.enqueue(batch)
        }
        pendingBytes = 0
        writeNow()
    }

    /// Seals everything and sends it now, a retry's wait included; [done] is told when nothing is in flight.
    package func flush(_ done: @escaping () -> Void) {
        seal(force: true)
        sender.sendNow()
        sender.whenIdle(done)
    }

    /// Going to the background: everything is written and sealed at once, since the process may never run again.
    package func onHidden() {
        seal(force: true)
        writeNow()
    }

    /// Deletes every event waiting, for an opt-out, a crash's row an earlier process left among them.
    package func clear() {
        pendingEvents.removeAll()
        pendingBytes = 0
        while sender.dropOldest() != nil {
            // Every batch the sender holds goes.
        }
        store.delete(EventQueue.crash)
        writeNow()
    }

    private func settleWait() -> Int64 {
        let now = clock.nowMicros()
        var wait: Int64 = 0
        for e in pendingEvents where e.isPageView {
            let left = settleMicros - (now - e.atMicros)
            if left > wait { wait = left }
            if let until = e.settleUntilMicros, until - now > wait { wait = until - now }
        }
        return wait
    }

    private func schedule() {
        if sealTimer != nil { return }
        guard let first = pendingEvents.first?.atMicros else { return }
        let wait = max(0, intervalMicros - (clock.nowMicros() - first))
        sealTimer = scheduler.schedule(wait) { [weak self] in self?.seal() }
    }

    private func scheduleWrite() {
        if writeTimer == nil {
            writeTimer = scheduler.schedule(250_000) { [weak self] in self?.writeNow() }
        }
    }

    private func writeNow() {
        writeTimer?.cancel()
        writeTimer = nil
        if !store.available { return }
        // Nothing is kept on the device while consent is not granted, and what
        // was kept before is not sent again by a later launch.
        if pendingEvents.isEmpty || !store.writable {
            store.delete(EventQueue.current)
            return
        }
        store.writeString(EventQueue.current, pendingEvents.map { Json.encode($0.toStored()) + "\n" }.joined())
    }

    private func enforceCaps() {
        func queuedEvents() -> Int { pendingEvents.count + sender.pending.reduce(0) { $0 + $1.events } }
        func queuedBytes() -> Int { pendingBytes + sender.pending.reduce(0) { $0 + $1.bytes } }
        while queuedEvents() > maxQueuedEvents || queuedBytes() > maxQueuedBytes {
            if let dropped = sender.dropOldest() {
                log?("the queue was full; \(dropped.events) of the oldest events were dropped")
                continue
            }
            if pendingEvents.count <= 1 { break }
            let e = pendingEvents.removeFirst()
            pendingBytes -= e.encodedLength
            log?("the queue was full; the oldest event was dropped")
        }
    }

    package func dispose() {
        sealTimer?.cancel()
        writeTimer?.cancel()
        writeNow()
    }
}
