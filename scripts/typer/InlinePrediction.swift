import AppKit
import Foundation
import SwiftUI

// macOS native inline-prediction clash (#4, spec E §4 / feature-mechanics §3).
//
// macOS Sonoma+ shows its own grey inline predictions in NSTextView/UITextView, driven by
// the GLOBAL default `NSAutomaticInlinePredictionEnabled`. When it's on, Apple's prediction
// and Typer's ghost text collide in the same field. Typer can't flip another app's text
// view, so the only lever is that global default.
//
// LOCKED product decision (impl-contract / spec H.1): ship GUIDE-by-default. We detect the
// clash and surface an onboarding card + a deep-link to Keyboard settings. The one-click
// write is an EXPLICIT, clearly-labelled opt-in button that records the prior value first so
// it can be restored on uninstall. We never silently write a global default.

enum InlinePrediction {
    // The Apple key + the typer-side record of the value we found before any write, so an
    // uninstaller / "reset" can restore exactly what the user had.
    static let appleKey = "NSAutomaticInlinePredictionEnabled"
    static let priorValueKey = "inlinePredictionPriorValue"   // in typer's own UserDefaults
    static let priorValueIsSetKey = "inlinePredictionPriorValueRecorded"

    // True when Apple's global inline prediction is currently enabled (the clash condition).
    // Reads the global preference domain (kCFPreferencesAnyApplication), matching the way the
    // default actually propagates to every app's text views.
    static func systemEnabled() -> Bool {
        CFPreferencesGetAppBooleanValue(appleKey as CFString, kCFPreferencesAnyApplication, nil)
    }

    // Has the user already turned it off (via us or anywhere else) since we last checked?
    static func clashActive(cfg: TyperConfig) -> Bool {
        cfg.inlinePredictionWarn && systemEnabled()
    }

    // Deep-link to the Keyboard settings pane where "Show inline predictive text" lives.
    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // The explicit opt-in write. Records the prior global value once (so it can be restored),
    // then writes the global default to false and synchronizes. Returns whether the write was
    // issued. The OS only applies it to text views created afterward, so callers must message
    // the user that a relaunch of the *target* app is needed (feature-mechanics §3).
    @discardableResult
    static func turnOffForMe() -> Bool {
        recordPriorValueIfNeeded()
        CFPreferencesSetValue(appleKey as CFString, kCFBooleanFalse,
                              kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let ok = CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        log("inline-prediction: wrote global \(appleKey)=false (sync=\(ok))")
        return ok
    }

    // Restore the prior global value we recorded before our first write (for uninstall/reset).
    // No-op if we never wrote it.
    static func restorePriorValue() {
        let d = UserDefaults.standard
        guard d.bool(forKey: priorValueIsSetKey) else { return }
        let prior = d.bool(forKey: priorValueKey)
        CFPreferencesSetValue(appleKey as CFString, prior ? kCFBooleanTrue : kCFBooleanFalse,
                              kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        _ = CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        d.removeObject(forKey: priorValueKey)
        d.removeObject(forKey: priorValueIsSetKey)
        log("inline-prediction: restored global \(appleKey)=\(prior)")
    }

    // Forget the recorded prior value WITHOUT touching the system default. Registered in
    // resetData() so "Reset All Data" clears the inline-prediction state per spec G.
    static func clearRecord() {
        let d = UserDefaults.standard
        d.removeObject(forKey: priorValueKey)
        d.removeObject(forKey: priorValueIsSetKey)
    }

    // Record the current global value the FIRST time only, so a later restore returns the
    // user's original choice rather than our own write.
    private static func recordPriorValueIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: priorValueIsSetKey) else { return }
        d.set(systemEnabled(), forKey: priorValueKey)
        d.set(true, forKey: priorValueIsSetKey)
    }
}

// MARK: - Onboarding card

// A small standalone window shown once when the clash is detected (and re-openable from the
// menu warning). Mirrors OnboardingController's controller + SwiftUI-host pattern.
final class InlinePredictionController {
    static let shared = InlinePredictionController()
    private var window: NSWindow?
    let model = InlinePredictionModel()

    func show(app: TyperApp) {
        model.app = app
        model.refresh()
        if let win = window {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: InlinePredictionCard(model: model))
        let win = NSWindow(contentViewController: host)
        win.title = "macOS Inline Prediction"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 440, height: 360))
        win.center()
        window = win
        model.onClose = { [weak self] in self?.window?.close() }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
}

final class InlinePredictionModel: ObservableObject {
    weak var app: TyperApp?
    @Published var systemEnabled = false
    @Published var didTurnOff = false
    var onClose: (() -> Void)?

    private var timer: Timer?

    func refresh() {
        systemEnabled = InlinePrediction.systemEnabled()
        // Stop polling once the clash is gone.
        if !systemEnabled { timer?.invalidate(); timer = nil }
    }

    func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func turnOff() {
        InlinePrediction.turnOffForMe()
        didTurnOff = true
        refresh()
    }

    func openSettings() {
        InlinePrediction.openKeyboardSettings()
        startPolling()      // flip the status the moment they toggle it in Settings
    }

    // The user chose to keep guiding only / dismiss. Don't nag again unless they re-open it.
    // `inline_prediction_warn` isn't a menu toggle, so persist it directly through the same
    // cfg + config.toml channel the setters use.
    func dismissForever() {
        if let app {
            app.cfg.inlinePredictionWarn = false
            app.writeConfig("inline_prediction_warn", "false")
        }
        onClose?()
    }
}

struct InlinePredictionCard: View {
    @ObservedObject var model: InlinePredictionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "text.cursor")
                    .font(.system(size: 26)).foregroundStyle(.tint)
                Text("Two suggestions at once").font(.system(size: 19, weight: .bold))
            }

            if model.systemEnabled {
                Text("macOS has its own inline predictions turned on. They appear as grey text right where Typer shows its suggestion, so you'll see both at once.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Turning off the macOS one lets Typer's suggestions stand on their own.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        model.openSettings()
                    } label: {
                        Label("Open Keyboard Settings", systemImage: "gearshape")
                    }
                    .help("Opens System Settings ▸ Keyboard, where “Show inline predictive text” lives. Recommended.")

                    Button {
                        model.turnOff()
                    } label: {
                        Label("Turn it off for me", systemImage: "wand.and.stars")
                    }
                    .help("Writes the macOS global setting for you (the value you had is saved so it can be restored). Apps you already have open need a relaunch to pick up the change.")
                }
                .padding(.top, 2)

                Text("“Turn it off for me” changes a system-wide macOS setting on your behalf. Already-open apps keep showing Apple's predictions until you relaunch them.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(model.didTurnOff ? "Done — macOS inline prediction is off." : "macOS inline prediction is already off. You're all set.")
                        .font(.system(size: 13))
                }
                if model.didTurnOff {
                    Text("Relaunch any apps you already had open so they stop showing Apple's predictions.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            HStack {
                Button("Don't show this again") { model.dismissForever() }
                    .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12))
                Spacer()
                Button("Done") { model.onClose?() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440, height: 360)
    }
}

extension TyperApp {
    // Show the inline-prediction onboarding card if the clash is active (called once at
    // launch after onboarding, and from the menu warning). Guide-by-default; the card hosts
    // the explicit opt-in write.
    func maybeWarnInlinePrediction() {
        guard InlinePrediction.clashActive(cfg: cfg) else { return }
        log("inline-prediction: macOS global prediction is ON — surfacing guide card")
        InlinePredictionController.shared.show(app: self)
    }

    // Explicit re-open from a menu item / warning row.
    func openInlinePredictionCard() {
        InlinePredictionController.shared.show(app: self)
    }
}
