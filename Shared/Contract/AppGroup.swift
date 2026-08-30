import Foundation

/// Which App Group suite this process can actually reach.
///
/// `$(APP_GROUP_ID)` — surfaced as the `AppGroupIdentifier` Info.plist key — is what the project ASKS
/// for. It is not necessarily what the install GETS. Two ways they diverge, both seen on the sideload
/// path this app ships through:
///
/// 1. The artifact carries no entitlements at all. A build made with `CODE_SIGNING_ALLOWED=NO` skips
///    `ProcessProductPackaging`, so no entitlements blob is embedded; a re-signer reading the app to
///    decide what to request finds nothing, and grants no group. (`scripts/build-ipa.sh` is the fix
///    for that half — it ad-hoc signs the entitlements INTO the artifact before packaging.)
/// 2. The signer grants a DIFFERENT id than the one asked for — a free-provisioning re-signer may
///    rewrite the group to a team-scoped name while leaving Info.plist untouched.
///
/// Either way `containerURL(forSecurityApplicationGroupIdentifier:)` on the declared id returns nil,
/// and then every consumer fails in the worst possible shape: `UserDefaults(suiteName:)` still hands
/// back a working object, but a PRIVATE per-process one. The widget's writes and the app's reads go to
/// different stores, both succeed, and nothing anywhere reports an error.
///
/// So resolve against what this process actually holds rather than what the build wanted. The app and
/// the extension run this identical resolution over their OWN bundle, so they agree on an id even when
/// it is not the declared one.
public enum AppGroup {

    /// The id the build asked for. Always a usable name, so callers have something to log.
    public static let declared: String =
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
            ?? "group.com.whoopmaxx.app"

    /// The group this process will use: the declared id when it resolves, else the first GRANTED id
    /// that does, else the declared id (unreachable, but named — `isProvisioned` is how you find out).
    public static let resolved: String = {
        if reachable(declared) { return declared }
        // Sorted, so two processes reading two separately-issued profiles still pick the same id.
        for candidate in granted().sorted() where reachable(candidate) { return candidate }
        return declared
    }()

    /// Whether `resolved` names a container this process can actually open.
    ///
    /// False means app↔widget sharing is dead on this install: taps logged from the widget will never
    /// reach the store and the widget will never see a published snapshot. Callable in Release on
    /// purpose — the `assert`-based canary could only ever fire in Debug on the simulator, which is
    /// exactly where provisioning is never broken.
    public static var isProvisioned: Bool { reachable(resolved) }

    static func reachable(_ id: String) -> Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil
    }

    /// App groups named by this bundle's own provisioning profile — what the signer actually granted.
    ///
    /// Empty when the app is unsigned, ad-hoc signed with no profile, or the profile will not parse.
    /// An empty list is not an error here: it just means there is nothing to fall back to and
    /// `resolved` stays on the declared id.
    static func granted() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let blob = try? Data(contentsOf: url),
              let plist = embeddedPlist(in: blob),
              let root = (try? PropertyListSerialization.propertyList(from: plist, format: nil))
                  as? [String: Any],
              let entitlements = root["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else { return [] }
        return groups
    }

    /// A `.mobileprovision` is a CMS envelope wrapping an XML plist. There is no public API to open the
    /// envelope on iOS, so carve the plist out by its document markers.
    ///
    /// FIRST `</plist>` after the header, not the last: in a CMS envelope the signed content comes
    /// before the certificates and signature, so the payload's terminator is the first one — searching
    /// backwards would risk swallowing trailing DER into the slice and failing to parse.
    static func embeddedPlist(in blob: Data) -> Data? {
        guard let start = blob.range(of: Data("<?xml".utf8)),
              let end = blob.range(of: Data("</plist>".utf8), in: start.lowerBound..<blob.endIndex)
        else { return nil }
        return Data(blob[start.lowerBound..<end.upperBound])
    }
}
