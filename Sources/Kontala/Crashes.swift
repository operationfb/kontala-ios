#if os(iOS)
    import Darwin
    import Foundation
    import KontalaCore

    /// Objective-C exceptions nothing in the app caught, as `js_error` rows, the Android SDK's `Crashes`: the uncaught
    /// exception handler is wrapped, and the row is written on the thread that crashed, before the handler it wraps
    /// runs, beside the queue (`queue/crash.jsonl`), which the next launch sends. It is stamped with what the core
    /// last published for it (`CrashContext`), so only while the property captures friction, consent is granted and
    /// the device may be written to.
    ///
    /// - **Name:** the exception's, `NSInvalidArgumentException`, where it is one a row may carry, else read from its
    ///   reason.
    /// - **Message:** the first line of its reason, normalised by the rules the tag and the collector share.
    /// - **Source:** the module of the app's own code it came from, and the type where its symbol says one,
    ///   `ios:ShopApp/CartViewController`; never the stack, and never a line, which an app's build keeps nowhere.
    /// - An exception within the served window of a tap names the tap's element and how long after it the error came.
    ///
    /// Only an exception while the app is on show is captured, and none the SDK raised itself. A crash reporter that
    /// sets its handler after the SDK runs before it, and calls it in turn, as they chain. Swift's own runtime errors,
    /// a force unwrap of nil or an index out of range, end the process by a signal, which this SDK leaves to the crash
    /// reporters that own the signal handlers: they are no row.
    final class Crashes {
        private typealias Handler = @convention(c) (NSException) -> Void

        private static let lock = NSLock()
        private static var reporting: Crashes?
        /// The handler this one wraps, and this one as the runtime holds it, while it is installed.
        private static var previous: Handler?
        private static var ours: Handler?
        private static let crashing = "la.konta.kontala.crashing"

        private let context: () -> CrashContext?
        private let lastTap: () -> LastTap?
        private let visible: () -> Bool
        private let now: () -> TimeInterval
        private let appRoot: String
        private let recorder = CrashRecorder()

        /// Each of [context], [lastTap] and [visible] is read on the thread that crashes.
        init(
            context: @escaping () -> CrashContext?, lastTap: @escaping () -> LastTap?, visible: @escaping () -> Bool,
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
            appRoot: String = Bundle.main.bundlePath
        ) {
            self.context = context
            self.lastTap = lastTap
            self.visible = visible
            self.now = now
            self.appRoot = appRoot
        }

        func install() {
            Crashes.lock.lock()
            defer { Crashes.lock.unlock() }
            Crashes.reporting = self
            if Crashes.ours != nil { return }
            Crashes.previous = NSGetUncaughtExceptionHandler()
            NSSetUncaughtExceptionHandler { e in Crashes.handle(e) }
            Crashes.ours = NSGetUncaughtExceptionHandler()
        }

        /// Puts the handler it wrapped back, where nothing has wrapped this one since; else this one passes every
        /// exception on, recording none.
        func uninstall() {
            Crashes.lock.lock()
            defer { Crashes.lock.unlock() }
            if Crashes.reporting === self { Crashes.reporting = nil }
            guard let mine = Crashes.ours, let h = NSGetUncaughtExceptionHandler(),
                unsafeBitCast(h, to: UnsafeRawPointer.self) == unsafeBitCast(mine, to: UnsafeRawPointer.self)
            else { return }
            NSSetUncaughtExceptionHandler(Crashes.previous)
            Crashes.previous = nil
            Crashes.ours = nil
        }

        private static func handle(_ e: NSException) {
            lock.lock()
            let r = reporting
            let p = previous
            lock.unlock()
            let thread = Thread.current.threadDictionary
            if let r = r, thread[crashing] == nil {
                thread[crashing] = true
                r.record(e)
                thread.removeObject(forKey: crashing)
            }
            p?(e)
        }

        /// Writes [e]'s row, where it is one; answers whether it did.
        @discardableResult
        func record(_ e: NSException) -> Bool {
            guard let c = context(), visible() else { return false }
            let frames = e.callStackReturnAddresses.map { Crashes.frame($0.uintValue) }
            guard case .app(let source) = Messages.iosOrigin(frames, appRoot: appRoot) else { return false }
            let tap = lastTap().map { TapBefore(ms: Int64(((now() - $0.at) * 1000).rounded()), fields: $0.fields) }
            return recorder.record(Thrown(name: e.name.rawValue, message: e.reason ?? "", source: source), c, tap: tap)
        }

        /// The image and the symbol a return address is in.
        static func frame(_ address: UInt) -> Messages.NativeFrame {
            var info = Dl_info()
            // A return address is just past its call, which can be the next function's first instruction.
            guard address > 0, let pc = UnsafeRawPointer(bitPattern: address - 1), dladdr(pc, &info) != 0 else {
                return Messages.NativeFrame(image: "")
            }
            let image = info.dli_fname.map { String(cString: $0) } ?? ""
            let symbol = info.dli_sname.map { String(cString: $0) }
            let offset = info.dli_saddr.map { Int(bitPattern: address - 1) - Int(bitPattern: $0) }
            return Messages.NativeFrame(image: image, symbol: symbol, offset: offset)
        }
    }
#endif
