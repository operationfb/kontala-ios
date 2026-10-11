#if os(iOS)
    import AdSupport
    import AppTrackingTransparency
    import Foundation
    import KontalaCore
    import UIKit

    /// What iOS says about the app and the device, the Flutter plugin's `Facts`: UIKit's answers on the main thread as
    /// the SDK starts, and the file system's on the core's queue.
    enum Facts {
        /// Whether the app runs in the simulator, which a developer's build does.
        static var simulator: Bool {
            #if targetEnvironment(simulator)
                return true
            #else
                return false
            #endif
        }

        /// The app and the device as UIKit says them, on the main thread: everything the core keeps for the process
        /// but the storage directory and the build, which the file system says.
        static func fromUIKit() -> PlatformFacts {
            let bundle = Bundle.main
            let info = bundle.infoDictionary ?? [:]
            let device = UIDevice.current
            let pad = device.userInterfaceIdiom == .pad
            return PlatformFacts(
                appId: bundle.bundleIdentifier ?? "unknown.app",
                appVersion: info["CFBundleShortVersionString"] as? String,
                appBuild: info["CFBundleVersion"] as? String,
                osName: pad ? "ipados" : "ios",
                osVersion: device.systemVersion,
                manufacturer: "Apple",
                model: machine(),
                timezone: TimeZone.current.identifier,
                isTablet: pad,
                isVirtual: simulator,
                processStartMicros: processStartMs().map { $0 * 1000 }
            )
        }

        /// When the process started, on the wall clock, in milliseconds, from the kernel's own record of it.
        static func processStartMs() -> Int64? {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
            guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else { return nil }
            let start = info.kp_proc.p_starttime
            let ms = Int64(start.tv_sec) * 1000 + Int64(start.tv_usec) / 1000
            return ms > 0 ? ms : nil
        }

        /// How the app was built: `debug` where its provisioning profile lets a debugger attach, as a development
        /// build's does, and in the simulator; `release` from the App Store, TestFlight, or a distribution profile.
        static func buildMode() -> String {
            if simulator { return "debug" }
            guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
                let data = try? Data(contentsOf: url)
            else {
                // The App Store and TestFlight embed no profile.
                return "release"
            }
            // The profile is a property list inside a signature: the list alone is read.
            let text = String(decoding: data, as: UTF8.self)
            guard let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>"),
                start.lowerBound < end.upperBound,
                let plist = try? PropertyListSerialization.propertyList(
                    from: Data(text[start.lowerBound..<end.upperBound].utf8), format: nil) as? [String: Any],
                let entitlements = plist["Entitlements"] as? [String: Any]
            else { return "release" }
            return (entitlements["get-task-allow"] as? Bool) == true ? "debug" : "release"
        }

        /// Whether the visitor allows ad tracking: App Tracking Transparency's status from iOS 14, as the API names it.
        static func trackingStatus() -> String {
            if #available(iOS 14, *) {
                switch ATTrackingManager.trackingAuthorizationStatus {
                case .authorized: return "authorized"
                case .denied: return "denied"
                case .restricted: return "restricted"
                case .notDetermined: return "not_determined"
                @unknown default: return "not_determined"
                }
            }
            return ASIdentifierManager.shared().isAdvertisingTrackingEnabled ? "authorized" : "denied"
        }

        /// The device's ids: the IDFV, nil before the first unlock after a restart, and the IDFA only where the
        /// visitor authorised tracking, which iOS gives as zeros otherwise.
        static func deviceIds() -> DeviceIds {
            let status = trackingStatus()
            var m: JSONObject = ["adTracking": .string(status)]
            if let idfv = UIDevice.current.identifierForVendor?.uuidString { m["idfv"] = .string(idfv) }
            if status == "authorized" {
                m["advertisingId"] = .string(ASIdentifierManager.shared().advertisingIdentifier.uuidString)
            }
            // Held to their shapes, and an id of zeros read as none.
            return DeviceIds.fromMap(m)
        }

        /// The machine identifier, `iPhone16,1`, which `UIDevice.model` ("iPhone") does not say; on a simulator, the
        /// device it simulates.
        static func machine() -> String? {
            #if targetEnvironment(simulator)
                return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
            #else
                var info = utsname()
                uname(&info)
                let id = withUnsafeBytes(of: &info.machine) { raw in
                    String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
                }
                return id.isEmpty ? nil : id
            #endif
        }

        /// Application Support, whose `kontala` directory, made here, is excluded from backups, so a backup restored
        /// to a new phone never makes two devices one.
        static func storageDirectory() -> String? {
            let fm = FileManager.default
            guard
                let base = try? fm.url(
                    for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            else { return nil }
            var dir = base.appendingPathComponent("kontala", isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try dir.setResourceValues(values)
            } catch {
                return nil
            }
            return base.path
        }
    }
#endif
