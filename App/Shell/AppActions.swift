import SwiftUI

/// Shell-level presenters any screen can trigger (037). The More tab is gone: Settings is a
/// sheet and Strap health a cover, both owned by `AppShell`, so a header gear on Today or the strap
/// chip does not need to know where they live. `AppShell` injects the real closures; the default
/// value is inert so previews and isolated screens render without a shell.
struct AppActions {
    /// Present the Settings sheet.
    var openSettings: () -> Void = {}
    /// Present the Strap health cover.
    var openStrapHealth: () -> Void = {}
}

private struct AppActionsKey: EnvironmentKey {
    static let defaultValue = AppActions()
}

extension EnvironmentValues {
    var appActions: AppActions {
        get { self[AppActionsKey.self] }
        set { self[AppActionsKey.self] = newValue }
    }
}
