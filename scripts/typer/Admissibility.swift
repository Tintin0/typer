import Foundation

// Per-app admissibility / backoff state and the built-in denylists (spec C.5, D.3, D.4).
//
// Three concerns live here, all shared across waves (W1B uses the backoff, W1C wires the
// denylists into `isAppDisabled`, W2A/B read them):
//   1. Exponential per-bundle capture backoff when an app errors/returns empty on AX/SCK.
//   2. Per-PID polling suspension (clears on relaunch).
//   3. The static password-manager + IDE/own-autocomplete bundle-id denylists.
//
// Thread-safe via a single lock; the maps auto-expire on read.

final class Admissibility {
    static let shared = Admissibility()

    private let lock = NSLock()
    // Auto-expiring: an app that errored on capture/AX is skipped until this deadline.
    private var inadmissibleUntil: [String: Date] = [:]
    // The current backoff length per bundle, doubled on each failure up to the ceiling.
    private var backoffStep: [String: TimeInterval] = [:]
    // PIDs whose polling is suspended for this launch (cleared by `clearPID` on relaunch).
    private var pollingSuspendedForPID: Set<pid_t> = []

    private let baseBackoff: TimeInterval = 2
    private let maxBackoff: TimeInterval = 60

    // Record a capture/AX failure for a bundle: extend (or start) its backoff window,
    // doubling the step each time up to ~60 s.
    func noteFailure(bundle: String) {
        guard !bundle.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let next = min((backoffStep[bundle] ?? 0) == 0 ? baseBackoff : backoffStep[bundle]! * 2, maxBackoff)
        backoffStep[bundle] = next
        inadmissibleUntil[bundle] = Date().addingTimeInterval(next)
    }

    // Record a successful capture for a bundle: clear its backoff entirely.
    func noteSuccess(bundle: String) {
        guard !bundle.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        inadmissibleUntil[bundle] = nil
        backoffStep[bundle] = nil
    }

    // True while the bundle is inside its backoff window (skip capture). Expired entries
    // are cleared as a side effect.
    func isBackedOff(bundle: String) -> Bool {
        guard !bundle.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let until = inadmissibleUntil[bundle] else { return false }
        if until > Date() { return true }
        inadmissibleUntil[bundle] = nil
        backoffStep[bundle] = nil
        return false
    }

    func suspendPolling(pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        pollingSuspendedForPID.insert(pid)
    }

    func isPollingSuspended(pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pollingSuspendedForPID.contains(pid)
    }

    func clearPID(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        pollingSuspendedForPID.remove(pid)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        inadmissibleUntil.removeAll()
        backoffStep.removeAll()
        pollingSuspendedForPID.removeAll()
    }

    // MARK: - Built-in denylists (spec D.3 / D.4)

    // Password managers / secret stores: completions ALWAYS suppressed here, not
    // user-overridable (privacy). Verified bundle ids from Cotypist + research/stability.md.
    static let passwordManagerBundles: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword", "com.apple.Passwords",
        "com.lastpass.LastPass", "com.lastpass.lastpassmacdesktop",
        "com.dashlane.Dashlane", "com.dashlane.dashlanephonefinal",
        "com.bitwarden.desktop", "com.keepersecurity.passwordmanager", "com.callpod.keepermac.lite",
        "com.sibersystems.RoboFormMac", "com.nordsec.nordpass", "in.sinew.Enpass-Desktop",
        "me.proton.pass.electron", "com.ascendo.DataVaultMac", "com.mseven.msecuremac",
        "com.symantec.NortonPasswordManager.combined", "org.keepassx.keepassx",
        "org.keepassxc.keepassxc", "com.selznick.PasswordWallet",
        "com.outercorner.Secrets", "com.outercorner.Secrets-setapp",
    ]

    // IDEs / editors / DB tools that ship their own autocomplete: completions suppressed
    // BY DEFAULT but overridable per app via `AppOverrides.completionsDisabled = false`.
    // (Terminals are handled separately by TyperApp.terminalBundleIDs + disableInTerminals.)
    static let ownAutocompleteBundles: Set<String> = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",      // Cursor
        "com.exafunction.windsurf",           // Windsurf
        "com.google.android.studio", "com.google.android.studio-EAP",
        "com.jetbrains.intellij", "com.jetbrains.intellij.ce",
        "com.jetbrains.intellij-EAP", "com.jetbrains.intellij.ce-EAP",
        "com.jetbrains.AppCode",
        "com.jetbrains.PhpStorm", "com.jetbrains.PhpStorm-EAP",
        "com.jetbrains.CLion", "com.jetbrains.CLion-EAP",
        "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce",
        "com.jetbrains.pycharm-EAP", "com.jetbrains.pycharm.ce-EAP",
        "com.jetbrains.goland", "com.jetbrains.goland-EAP",
        "com.jetbrains.rider", "com.jetbrains.rider-EAP",
        "com.jetbrains.rubymine", "com.jetbrains.rubymine-EAP",
        "com.sublimetext.2", "com.sublimetext.3",
        "com.mathworks.matlab", "org.rstudio.RStudio",
        "com.tinyapp.TablePlus", "com.tinyapp.TablePlus-setapp",
    ]
}
