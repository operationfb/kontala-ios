import Foundation

/// A request body sealed and written to disk before it is sent, so a process killed mid-flight sends the same body,
/// with the same event ids, next time.
package final class SealedBatch {
    package let id: String
    package let body: JSONObject
    package let events: Int

    package init(_ id: String, _ body: JSONObject, _ events: Int) {
        self.id = id
        self.body = body
        self.events = events
    }

    package var fileName: String { "queue/sealed/\(id).json" }

    /// The body without `sent_at`, which is the send's own time.
    package var bytes: Int { utf8Length(Json.encode(body)) }
}

/// One event the API refused, or warned of, by its index in the request.
package struct Refusal {
    package let index: Int
    package let id: String?
    package let code: String
    package let message: String
}

/// What became of a request.
package enum SendOutcome {
    /// Read: every event not refused was stored.
    case delivered(accepted: Int, refused: [Refusal], warnings: [Refusal])
    /// Refused whole, and not to be sent again: an SDK fault.
    case dropped(status: Int, code: String, message: String)
    /// The key was refused: unknown, revoked, or another region's.
    case halted(code: String)
}

/// Sends sealed batches to the Events API, one request at a time, which keeps a device inside its bucket and its
/// events in order.
///
/// | Response                            | Done                                                                        |
/// |-------------------------------------|-----------------------------------------------------------------------------|
/// | 200                                 | Final; refusals are reported by index.                                      |
/// | 429, 503                            | Retried after `Retry-After`, with jitter, and the same body.                |
/// | Network error, timeout, another 5xx | Retried with exponential backoff, 1 s doubling to 5 min.                    |
/// | 413                                 | Split in half and retried.                                                  |
/// | 400 `unknown_field`                 | Written again at the contract before and sent, where it held anything later. |
/// | 400, 403, 415                       | Dropped as an SDK fault.                                                    |
/// | 401                                 | Kept; sending stops for the process.                                        |
///
/// Only the core's queue calls it; each answer is posted back there.
package final class Sender {
    package static let maxBackoffMs: Int64 = 5 * 60 * 1000
    package static let gzipAbove = 1024

    private let endpoint: String
    private let writeKey: String
    private let store: FileStore
    private let clock: Clock
    private let libraryVersion: String
    private let http: Http
    private let scheduler: Scheduler
    private let onOutcome: ((SealedBatch, SendOutcome) -> Void)?
    /// Told when the collector refused a request for a field it does not read and a copy of it at the contract before
    /// was sent instead.
    private let onContractRefused: (() -> Void)?
    private let log: ((String) -> Void)?
    private let random: () -> Double

    private var batches: [SealedBatch] = []
    private var inFlight = false
    package private(set) var halted = false
    private var failures = 0
    private var retry: Cancellable?
    private var idle: [() -> Void] = []

    package init(
        endpoint: String, writeKey: String, store: FileStore, clock: Clock, libraryVersion: String, http: Http,
        scheduler: Scheduler, onOutcome: ((SealedBatch, SendOutcome) -> Void)? = nil,
        onContractRefused: (() -> Void)? = nil, log: ((String) -> Void)? = nil,
        random: @escaping () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.endpoint = endpoint
        self.writeKey = writeKey
        self.store = store
        self.clock = clock
        self.libraryVersion = libraryVersion
        self.http = http
        self.scheduler = scheduler
        self.onOutcome = onOutcome
        self.onContractRefused = onContractRefused
        self.log = log
        self.random = random
    }

    /// The batches waiting, oldest first.
    package var pending: [SealedBatch] { batches }

    /// Stops sending for the process, as a refused key does: the configuration is read with the same key.
    package func halt() {
        halted = true
        settleIdle()
    }

    package func enqueue(_ batch: SealedBatch) {
        batches.append(batch)
        pump()
    }

    /// Drops the oldest batch, for the queue's caps.
    @discardableResult
    package func dropOldest() -> SealedBatch? {
        if batches.isEmpty { return nil }
        if inFlight && batches.count == 1 { return nil }
        let b = batches.removeFirst()
        store.delete(b.fileName)
        return b
    }

    /// Sends what can be sent now, without waiting for a retry's timer.
    package func sendNow() {
        retry?.cancel()
        retry = nil
        pump()
    }

    /// Calls [done] when nothing is in flight and nothing is waiting but what a retry or a halt holds back.
    package func whenIdle(_ done: @escaping () -> Void) {
        if !inFlight && (batches.isEmpty || halted || retry != nil) {
            done()
            return
        }
        idle.append(done)
    }

    private func settleIdle() {
        if inFlight { return }
        if !batches.isEmpty && !halted && retry == nil { return }
        let waiting = idle
        idle.removeAll()
        for f in waiting { f() }
    }

    private func pump() {
        if inFlight || halted || retry != nil || batches.isEmpty {
            settleIdle()
            return
        }
        let batch = batches[0]
        inFlight = true
        var body = batch.body
        body["sent_at"] = .string(rfc3339(clock.nowMicros()))
        var bytes = Data(Json.encode(body).utf8)
        var headers: [String: String] = [:]
        headers["Authorization"] = "Bearer \(writeKey)"
        headers["Content-Type"] = "application/json"
        headers["User-Agent"] = "\(sdkLibraryName)/\(libraryVersion)"
        if bytes.count > Sender.gzipAbove, let zipped = gzip(bytes) {
            bytes = zipped
            headers["Content-Encoding"] = "gzip"
        }
        http.post(endpoint, headers, bytes) { [weak self] answer, error in
            guard let self = self else { return }
            self.scheduler.post {
                self.inFlight = false
                self.answered(batch, answer, error)
                self.pump()
            }
        }
    }

    private func answered(_ batch: SealedBatch, _ answer: HttpAnswer?, _ error: Error?) {
        guard let answer = answer else {
            backoff("network: \(error.map { "\($0)" } ?? "no answer")")
            return
        }
        if let d = answer.date, let at = parseHttpDate(d) { clock.observeServerTime(at) }
        let body = Json.decodeObject(answer.body) ?? JSONObject()
        switch answer.status {
        case 200:
            failures = 0
            finish(batch, delivered(body))
        case 429, 503:
            retryAfter(parseRetryAfter(answer.retryAfter), "status \(answer.status)")
        case 413:
            failures = 0
            split(batch)
        case 401:
            halted = true
            log?("the write key was refused (\(code(body))); sending stops until the app starts again")
            onOutcome?(batch, .halted(code: code(body)))
        case 400, 403, 415:
            if answer.status == 400 && code(body) == "unknown_field" && downgrade(batch) {
                failures = 0
                return
            }
            failures = 0
            let c = code(body)
            let m = message(body)
            log?("a request was refused whole (\(answer.status) \(c)): \(m)")
            finish(batch, .dropped(status: answer.status, code: c, message: m))
        default:
            backoff("status \(answer.status)")
        }
    }

    /// Replaces a batch a collector refused for a field it does not read with its copy at the contract before, kept on
    /// disk as the batch was, and answers whether the refusal was that: a body with nothing of a later contract in it
    /// is an SDK fault, and dropped as one. A batch of a later contract's kinds alone has nothing left to send, and is
    /// done.
    private func downgrade(_ batch: SealedBatch) -> Bool {
        guard let body = WireEncoder.downgrade(batch.body) else { return false }
        if batches.first !== batch { return false }
        let left = body.list("events")?.count ?? 0
        log?(
            "the collector does not read the contract the request was written at; "
                + "it is sent again at the one before, \(batch.events - left) events left out")
        onContractRefused?()
        if left == 0 {
            finish(batch, .delivered(accepted: 0, refused: [], warnings: []))
            return true
        }
        let copy = SealedBatch(batch.id, body, left)
        store.writeJson(copy.fileName, body)
        batches[0] = copy
        return true
    }

    private func finish(_ batch: SealedBatch, _ outcome: SendOutcome) {
        if batches.first === batch { batches.removeFirst() }
        store.delete(batch.fileName)
        onOutcome?(batch, outcome)
    }

    private func split(_ batch: SealedBatch) {
        let events = batch.body.list("events") ?? []
        if batches.first === batch { batches.removeFirst() }
        store.delete(batch.fileName)
        if events.count < 2 {
            log?("one event was larger than the API takes, and was dropped")
            onOutcome?(batch, .dropped(status: 413, code: "body_too_large", message: "one event over the limit"))
            return
        }
        let half = events.count / 2
        let parts = [Array(events[..<half]), Array(events[half...])]
        for i in parts.indices.reversed() {
            var body = batch.body
            body["events"] = .array(parts[i])
            let part = SealedBatch("\(batch.id)-\(i + 1)", body, parts[i].count)
            store.writeJson(part.fileName, body)
            batches.insert(part, at: 0)
        }
    }

    private func retryAfter(_ afterMicros: Int64?, _ why: String) {
        let wait = afterMicros ?? nextBackoff()
        let jitter = Int64((Double(wait) * 0.2 * random()).rounded())
        log?("\(why); retrying in \((wait + jitter) / 1_000_000) s")
        retry = scheduler.schedule(wait + jitter) { [weak self] in
            self?.retry = nil
            self?.pump()
        }
    }

    private func backoff(_ why: String) {
        failures += 1
        retryAfter(nextBackoff(), why)
    }

    private func nextBackoff() -> Int64 {
        let ms = min(Sender.maxBackoffMs, 1000 * (Int64(1) << Int64(max(0, min(failures - 1, 20)))))
        return ms * 1000
    }

    private func parseRetryAfter(_ v: String?) -> Int64? {
        guard let v = v else { return nil }
        if let s = Int64(v.trimmingCharacters(in: .whitespaces)) { return max(0, s) * 1_000_000 }
        guard let at = parseHttpDate(v) else { return nil }
        let d = at - Int64(Date().timeIntervalSince1970 * 1000)
        return d < 0 ? 0 : d * 1000
    }

    private func code(_ body: JSONObject) -> String { body.obj("error")?.str("code") ?? "unknown" }

    private func message(_ body: JSONObject) -> String { body.obj("error")?.str("message") ?? "" }

    private func delivered(_ body: JSONObject) -> SendOutcome {
        func issues(_ v: JSON?) -> [Refusal] {
            (v?.array ?? []).compactMap { i in
                guard let m = i.object else { return nil }
                return Refusal(
                    index: m["index"]?.number.map { Int($0) } ?? -1, id: m.str("id"), code: m.str("code") ?? "unknown",
                    message: m.str("message") ?? "")
            }
        }
        return .delivered(
            accepted: body["accepted"]?.number.map { Int($0) } ?? 0,
            refused: issues(body["rejected"]),
            warnings: issues(body["warnings"]))
    }

    package func close() {
        retry?.cancel()
        retry = nil
    }
}
