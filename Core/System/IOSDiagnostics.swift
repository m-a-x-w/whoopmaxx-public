// Derived from ParthJadhav/noop, PolyForm Noncommercial License 1.0.0, Copyright 2026 NoopApp.
// Required Notice: Copyright 2026 NoopApp (https://github.com/ParthJadhav/noop)
// Terms: https://polyformproject.org/licenses/noncommercial/1.0.0 — see ../../LICENSE.

import Foundation
import UIKit

/// A snapshot of the iOS-side facts that quietly break a sideloaded health app: which OS build is
/// running, whether Data Protection still has the file vault locked after a reboot, whether
/// Background App Refresh was denied, whether Low Power Mode is throttling BLE, and when the
/// sideload profile expires. None of that shows up in a normal crash log, so it is captured here and
/// pasted into the bug report verbatim.
///
/// Every field is optional with a nil default so a partially-known snapshot is constructible and so
/// an unreadable fact stays absent instead of being reported as a plausible-looking default. A bug
/// report that invents "Low Power Mode: off" is worse than one that omits the line.
struct IOSDiagnostics {

    /// Hardware model identifier, e.g. "iPhone16,2".
    var deviceModel: String? = nil
    /// Full OS version string including the build number; the build suffix is what reveals a beta.
    var osVersionString: String? = nil
    /// False means the device has not been unlocked since boot, so protected files are unreadable and
    /// no history can be written until the user unlocks once.
    var isProtectedDataAvailable: Bool? = nil
    /// Background App Refresh state, already rendered for a human reader.
    var backgroundRefresh: String? = nil
    /// Low Power Mode, which throttles background work and BLE scanning.
    var isLowPowerMode: Bool? = nil
    /// Whether this build looks sideloaded (dev / AltStore / free Apple ID) rather than App Store.
    var isSideloaded: Bool? = nil
    /// Expiry of the embedded provisioning profile, when one is present and parseable.
    var sideloadExpiry: Date? = nil

    /// Read the current environment.
    ///
    /// `@MainActor` because the two UIKit reads below are main-actor state. Its one caller,
    /// `InstallReport.capture()`, is `@MainActor` for the same reason, so the requirement is now a
    /// compile-time fact rather than an `assumeIsolated` trap waiting for a future off-main caller.
    @MainActor
    static func capture() -> IOSDiagnostics {
        let app = UIApplication.shared
        let protectedData = app.isProtectedDataAvailable
        let refreshText = backgroundRefreshText(app.backgroundRefreshStatus)
        let info = ProcessInfo.processInfo
        return IOSDiagnostics(
            deviceModel: machineIdentifier(),
            osVersionString: info.operatingSystemVersionString,
            isProtectedDataAvailable: protectedData,
            backgroundRefresh: refreshText,
            isLowPowerMode: info.isLowPowerModeEnabled,
            isSideloaded: isSideloadedBuild(),
            sideloadExpiry: provisioningExpiryDate()
        )
    }

    /// Whole days from today to the profile's expiry day, negative once it has passed. Day-boundary
    /// arithmetic, not elapsed hours: a profile expiring later today should read 0, not -1.
    func expiryDaysRemaining() -> Int? {
        guard let expiry = sideloadExpiry else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day],
                                  from: cal.startOfDay(for: Date()),
                                  to: cal.startOfDay(for: expiry)).day
    }

    /// The environment block for a bug report, one fact per line and unindented; the report adds its
    /// own indentation under the DEVICE heading. A nil field contributes no line at all.
    func summaryLines() -> [String] {
        var lines = ["Device: \(deviceModel ?? "unknown")"]
        if let os = osVersionString {
            lines.append("iOS: \(os)")
        }
        if let unlocked = isProtectedDataAvailable {
            lines.append(unlocked
                ? "Data Protection: unlocked (files readable)"
                : "Data Protection: LOCKED - unlock once after reboot so history can sync")
        }
        if let refresh = backgroundRefresh {
            lines.append("Background refresh: \(refresh)")
        }
        if let lowPower = isLowPowerMode {
            lines.append(lowPower ? "Low Power Mode: ON (throttles background BLE)" : "Low Power Mode: off")
        }
        if let sideloaded = isSideloaded {
            lines.append(sideloaded ? "Sideloaded build: yes" : "Sideloaded build: no (App Store / TestFlight)")
        }
        if let days = expiryDaysRemaining() {
            if days < 0 {
                let ago = -days
                lines.append("Sideload expiry: EXPIRED \(ago) day\(ago == 1 ? "" : "s") ago - re-sign to relaunch")
            } else {
                lines.append("Sideload expiry: \(days) day\(days == 1 ? "" : "s") remaining")
            }
        }
        return lines
    }

    // MARK: - Probes

    /// `uname` is the only way to get the model identifier; `UIDevice.model` returns "iPhone" for every
    /// handset ever made. On the Simulator this reports the host arch ("arm64"), which is accurate and
    /// not worth special-casing.
    private static func machineIdentifier() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return machine.isEmpty ? "unknown" : machine
    }

    private static func backgroundRefreshText(_ status: UIBackgroundRefreshStatus) -> String {
        switch status {
        case .available: return "Available"
        case .denied: return "Denied (off in Settings)"
        case .restricted: return "Restricted (parental/MDM)"
        @unknown default: return "Unknown"
        }
    }

    /// Both halves are required. A profile alone does not mean sideloaded (TestFlight builds ship one
    /// too), and a missing receipt alone does not either, so the pair is what separates an AltStore
    /// install from a store install.
    private static func isSideloadedBuild() -> Bool {
        guard Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") != nil else {
            return false
        }
        guard let receipt = Bundle.main.appStoreReceiptURL else { return true }
        return !FileManager.default.fileExists(atPath: receipt.path)
    }

    /// A `.mobileprovision` is a CMS envelope, and the carve that opens it lives in
    /// `AppGroup.embeddedPlist(in:)` because App Group resolution needs the identical slice. This file
    /// once held a second copy; the two drifted. Core compiles against Shared, so call the one that is
    /// under test rather than re-inlining it here.
    ///
    /// Any failure returns nil. An install with no readable profile must show as "no profile", never as
    /// a fabricated date that would make an expired sideload look healthy.
    private static func provisioningExpiryDate() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let blob = try? Data(contentsOf: url),
              let plistData = AppGroup.embeddedPlist(in: blob),
              let plist = try? PropertyListSerialization.propertyList(
                  from: plistData, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }
}
