import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

// Power-source awareness so we can throttle the (GPU-heavy) model when running on
// battery. Polling IOKit on every keystroke is wasteful, so the battery state is
// cached and refreshed lazily (no idle timer — checked only when we're about to
// generate). On a desktop with no battery this always reports AC, so nothing is
// throttled there.
final class PowerState {
    static let shared = PowerState()
    private var cachedOnBattery = false
    private var checkedAt = Date.distantPast

    func onBattery() -> Bool {
        if Date().timeIntervalSince(checkedAt) > 5 {
            // kIOPSTimeRemainingUnlimited is returned only when on AC power.
            cachedOnBattery = IOPSGetTimeRemainingEstimate() != kIOPSTimeRemainingUnlimited
            checkedAt = Date()
        }
        return cachedOnBattery
    }

    // Low Power Mode OR running on battery → back off to save energy.
    var saving: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled || onBattery() }
}
