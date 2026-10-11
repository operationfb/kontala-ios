import Foundation

@testable import KontalaCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// One request a `LocalCollector` read: its headers, in lower case, its body as JSON, and when it came.
struct Received {
    let headers: [String: String]
    let body: JSONObject
    let atMillis: Int64

    var ids: [String] { (body.list("events") ?? []).map { $0.object!.str("id")! } }
}

/// What a `LocalCollector` answers with.
struct Reply {
    var status: Int
    var body: String = ""
    var headers: [String: String] = [:]
}

/// A collector on a free port of the loopback interface, HTTP/1.1 over a plain socket, one connection at a time, so
/// the transport is held to a real socket through the platform's own client, as the other SDKs' transport tests are.
/// [answer] writes each response, by the number of the request it answers, from 0.
final class LocalCollector {
    private let lock = NSLock()
    private var receivedList: [Received] = []
    private let fd: Int32
    private(set) var port: UInt16 = 0
    private let answer: (Int, JSONObject) -> Reply
    private var closed = false

    init(_ answer: @escaping (Int, JSONObject) -> Reply) {
        self.answer = answer
        #if canImport(Darwin)
            fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
            fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        #if canImport(Darwin)
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(bound == 0, "could not bind: errno \(errno)")
        precondition(listen(fd, 16) == 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        port = UInt16(bigEndian: addr.sin_port)
        let thread = Thread { [weak self] in self?.serve() }
        thread.start()
    }

    var endpoint: String { "http://127.0.0.1:\(port)/v1/events" }

    var received: [Received] {
        lock.lock()
        defer { lock.unlock() }
        return receivedList
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
        shutdown(fd, Int32(SHUT_RDWR))
        #if canImport(Darwin)
            Darwin.close(fd)
        #else
            Glibc.close(fd)
        #endif
    }

    private func serve() {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { return }
            handle(c)
            #if canImport(Darwin)
                Darwin.close(c)
            #else
                Glibc.close(c)
            #endif
        }
    }

    private func readSome(_ c: Int32, _ into: inout [UInt8]) -> Bool {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        let n = buf.withUnsafeMutableBytes { recv(c, $0.baseAddress, $0.count, 0) }
        if n <= 0 { return false }
        into.append(contentsOf: buf[0..<n])
        return true
    }

    private func send(_ c: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        var at = 0
        while at < bytes.count {
            let n = bytes[at...].withUnsafeBytes { Glue.send(c, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            at += n
        }
    }

    private func handle(_ c: Int32) {
        var data: [UInt8] = []
        let separator: [UInt8] = [13, 10, 13, 10]
        var headerEnd: Int?
        while headerEnd == nil {
            if !readSome(c, &data) { return }
            if data.count >= 4 {
                for i in 0...(data.count - 4) where Array(data[i..<i + 4]) == separator {
                    headerEnd = i
                    break
                }
            }
        }
        let head = String(decoding: data[0..<headerEnd!], as: UTF8.self)
        var headers: [String: String] = [:]
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(
                in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        if headers["expect"]?.lowercased() == "100-continue" { send(c, "HTTP/1.1 100 Continue\r\n\r\n") }
        var body = Array(data[(headerEnd! + 4)...])
        while body.count < length {
            if !readSome(c, &body) { return }
        }
        var raw = Data(body.prefix(length))
        if headers["content-encoding"] == "gzip" { raw = gunzip(raw) ?? Data() }
        let json = Json.decodeObject(raw) ?? JSONObject()
        lock.lock()
        let n = receivedList.count
        receivedList.append(
            Received(headers: headers, body: json, atMillis: Int64(Date().timeIntervalSince1970 * 1000)))
        lock.unlock()
        let r = answer(n, json)
        var out = "HTTP/1.1 \(r.status) \(r.status == 200 ? "OK" : "Status")\r\n"
        out += "Content-Type: application/json\r\n"
        for (k, v) in r.headers { out += "\(k): \(v)\r\n" }
        out += "Content-Length: \(r.body.utf8.count)\r\nConnection: close\r\n\r\n\(r.body)"
        send(c, out)
    }
}

/// The C library's `send`, which a method of the same name would otherwise shadow.
private enum Glue {
    static func send(_ fd: Int32, _ p: UnsafeRawPointer?, _ n: Int) -> Int {
        #if canImport(Darwin)
            return Darwin.send(fd, p, n, 0)
        #else
            return Glibc.send(fd, p, n, 0)
        #endif
    }
}
