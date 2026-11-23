import Foundation

/// Reads the App Group out of an `embedded.mobileprovision`. Sideloading tools often rename
/// the group (e.g. append the Team ID), so the profile is the source of truth at runtime.
public enum ProvisioningProfile {
    /// The profile is a signed (CMS) blob with a plain XML plist inside; pull that plist out.
    public static func appGroup(fromProfileData data: Data) -> String? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else { return nil }
        return groups.first { !$0.contains("*") }
    }

    public static func appGroup(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return appGroup(fromProfileData: data)
    }
}
