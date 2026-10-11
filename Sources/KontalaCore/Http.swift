import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// What a request was answered with: its status, at most 256 KiB of its body, and the `Retry-After` and `Date` headers
/// as sent.
package struct HttpAnswer {
    package let status: Int
    package let body: Data
    package let retryAfter: String?
    package let date: String?

    package init(_ status: Int, _ body: Data = Data(), retryAfter: String? = nil, date: String? = nil) {
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
        self.date = date
    }
}

/// The SDK's two requests, each answered by calling `done` once, on any thread, with the answer or what went wrong:
/// the core posts it back to its own queue. A test answers them itself.
package protocol Http: AnyObject {
    func post(_ url: String, _ headers: [String: String], _ body: Data, _ done: @escaping (HttpAnswer?, Error?) -> Void)

    func get(_ url: String, _ headers: [String: String], _ done: @escaping (HttpAnswer?, Error?) -> Void)
}

/// `URLSession`, with a session of its own that keeps no cookies, no cache and no credentials, and follows no redirect,
/// one request at a time, which keeps a device inside its bucket and its events in order. The platform's client, so
/// the SDK brings no HTTP library into an app.
package final class SessionHttp: Http {
    private let session: URLSession
    private let gate = DispatchSemaphore(value: 1)
    private let work = DispatchQueue(label: "kontala-net", qos: .utility)

    package init(connectTimeout: TimeInterval = 10, readTimeout: TimeInterval = 30) {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = readTimeout
        c.timeoutIntervalForResource = connectTimeout + readTimeout * 2
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCredentialStorage = nil
        let serial = OperationQueue()
        serial.maxConcurrentOperationCount = 1
        session = URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: serial)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    package func post(
        _ url: String, _ headers: [String: String], _ body: Data, _ done: @escaping (HttpAnswer?, Error?) -> Void
    ) {
        run(url, "POST", headers, body, done)
    }

    package func get(_ url: String, _ headers: [String: String], _ done: @escaping (HttpAnswer?, Error?) -> Void) {
        run(url, "GET", headers, nil, done)
    }

    private struct BadURL: Error {}

    private func run(
        _ url: String, _ method: String, _ headers: [String: String], _ body: Data?,
        _ done: @escaping (HttpAnswer?, Error?) -> Void
    ) {
        guard let u = URL(string: url) else {
            done(nil, BadURL())
            return
        }
        var r = URLRequest(url: u)
        r.httpMethod = method
        r.httpShouldHandleCookies = false
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = body
        let request = r
        // One request at a time: the next starts once the last was answered.
        work.async { [weak self] in
            guard let self = self else { return done(nil, BadURL()) }
            self.gate.wait()
            let task = self.session.dataTask(with: request) { data, response, error in
                defer { self.gate.signal() }
                guard let r = response as? HTTPURLResponse else {
                    done(nil, error ?? BadURL())
                    return
                }
                let bytes = data.map { $0.count > 256 * 1024 ? $0.prefix(256 * 1024) : $0 } ?? Data()
                done(
                    HttpAnswer(
                        r.statusCode, Data(bytes), retryAfter: SessionHttp.header(r, "Retry-After"),
                        date: SessionHttp.header(r, "Date")),
                    nil)
            }
            task.resume()
        }
    }

    private static func header(_ r: HTTPURLResponse, _ name: String) -> String? {
        for (k, v) in r.allHeaderFields {
            if let key = k as? String, key.caseInsensitiveCompare(name) == .orderedSame { return v as? String }
        }
        return nil
    }

    package func close() {
        session.invalidateAndCancel()
    }
}

/// A redirect is never followed: a collector that moves answers with what it moved to, which the SDK reads as a
/// refusal. A delegate of its own, holding nothing, since a session holds its delegate until it is invalidated.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
