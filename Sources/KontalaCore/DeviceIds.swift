/// The platform's own ids for the device, beside the install id a row's device is, never as it, and whether the
/// visitor allows ad tracking: read only once consent is granted, since reading an id off a device needs the same
/// consent as storing one.
package struct DeviceIds: Equatable {
    /// iOS's identifierForVendor: one per vendor and device.
    package var idfv: String?
    /// Android's ANDROID_ID: one per signing key, user and device since Android 8.
    package var androidId: String?
    /// Android's App Set ID, one per developer account, with Play services.
    package var appSetId: String?
    /// The IDFA or Android's advertising id, never an id of all zeros.
    package var advertisingId: String?
    /// authorized, denied, restricted or not_determined on iOS; allowed or limited on Android.
    package var adTracking: String?

    package init(
        idfv: String? = nil, androidId: String? = nil, appSetId: String? = nil, advertisingId: String? = nil,
        adTracking: String? = nil
    ) {
        self.idfv = idfv
        self.androidId = androidId
        self.appSetId = appSetId
        self.advertisingId = advertisingId
        self.adTracking = adTracking
    }

    package var isEmpty: Bool {
        idfv == nil && androidId == nil && appSetId == nil && advertisingId == nil && adTracking == nil
    }

    /// The ids as the Events API's `context.device.ids` reads them.
    package func idsJson() -> JSONObject {
        var o = JSONObject()
        if let v = idfv { o["idfv"] = .string(v) }
        if let v = androidId { o["android_id"] = .string(v) }
        if let v = appSetId { o["app_set_id"] = .string(v) }
        if let v = advertisingId { o["advertising_id"] = .string(v) }
        return o
    }

    package func toJson() -> JSONObject {
        var o = JSONObject()
        if let v = idfv { o["idfv"] = .string(v) }
        if let v = androidId { o["androidId"] = .string(v) }
        if let v = appSetId { o["appSetId"] = .string(v) }
        if let v = advertisingId { o["advertisingId"] = .string(v) }
        if let v = adTracking { o["adTracking"] = .string(v) }
        return o
    }

    private static let uuid = Pattern("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
    private static let androidIdShape = Pattern("^[0-9A-Fa-f]{16}$")
    private static let tracking: Set<String> = [
        "authorized", "denied", "restricted", "not_determined", "allowed", "limited",
    ]

    /// What the platform read, each id held to its shape and an id of all zeros read as none: the API refuses an event
    /// for a malformed one.
    package static func fromMap(_ m: JSONObject) -> DeviceIds {
        func id(_ key: String, _ shape: Pattern) -> String? {
            guard let v = m.str(key), shape.matches(v) else { return nil }
            return v.allSatisfy({ $0 == "-" || $0 == "0" }) ? nil : v
        }
        let t = m.str("adTracking")
        return DeviceIds(
            idfv: id("idfv", uuid),
            androidId: id("androidId", androidIdShape),
            appSetId: id("appSetId", uuid),
            advertisingId: id("advertisingId", uuid),
            adTracking: t.flatMap { tracking.contains($0) ? $0 : nil }
        )
    }
}
