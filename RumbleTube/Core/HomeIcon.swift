import Foundation

/// iOS only lets an app switch between icons built into it, so a photo of your own goes on the
/// Home Screen as a Web Clip (installed from a small configuration profile) that opens the app.
enum HomeIconProfile {
    static let openURL = "rumbletube://open"

    static func make(name: String, iconPNG: Data, bundleID: String?, uuid: UUID = UUID()) throws -> Data {
        let label = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
        var clip: [String: Any] = [
            "PayloadType": "com.apple.webClip.managed",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.hostus300.rumbletube.homeicon.clip.\(uuid.uuidString)",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "Home Screen icon",
            "Label": label.isEmpty ? "Rumble" : label,
            "URL": openURL,
            "Icon": iconPNG,
            "IsRemovable": true,
            "FullScreen": true,
            "Precomposed": true,
        ]
        if let bundleID { clip["TargetApplicationBundleIdentifier"] = bundleID }
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.hostus300.rumbletube.homeicon.\(uuid.uuidString)",
            "PayloadUUID": uuid.uuidString,
            "PayloadDisplayName": "\(label.isEmpty ? "Rumble" : label) icon",
            "PayloadDescription": "Adds a Home Screen icon with your own picture that opens RumbleTube.",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [clip],
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }
}
