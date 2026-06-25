import AppKit
import Foundation

// "Let's Move to /Applications" (#12, spec E §12 / swift-techniques.md §9).
//
// typer builds straight into ~/Applications/Typer.app, so this is a FRIENDLY OFFER, not a forced
// move. It matters for a distributed DMG build: running from ~/Downloads or a mounted DMG breaks
// the self-update path and re-prompts TCC on every launch, and Gatekeeper App Translocation runs a
// quarantined app from a random read-only path (so its bundle URL isn't where the user dropped it).
// Moving to /Applications clears translocation and makes permissions/updates stick.
//
// Called once at the very top of applicationDidFinishLaunching (before onboarding/permission
// prompts). On accepting the move we copy into /Applications, relaunch the moved copy, and quit.
extension TyperApp {
    // Offer to relocate the app into /Applications when it's running from elsewhere
    // (Downloads, a mounted DMG, or a translocated read-only path).
    func maybeOfferMoveToApplications() {
        let fm = FileManager.default
        let bundleURL = Bundle.main.bundleURL
        let bundlePath = bundleURL.path

        let translocated = bundlePath.contains("/AppTranslocation/")
        let appsDir = fm.urls(for: .applicationDirectory, in: .localDomainMask).first
            ?? URL(fileURLWithPath: "/Applications")
        let alreadyInApplications = bundlePath.hasPrefix(appsDir.path + "/")

        // Already in /Applications and not running from a translocated copy → nothing to do.
        // (A translocated launch reports a /private/var/folders path, never /Applications, so the
        // hasPrefix check is only authoritative for non-translocated runs.)
        if alreadyInApplications && !translocated {
            maybeOfferRecommendedModel()
            return
        }

        let dest = appsDir.appendingPathComponent(bundleURL.lastPathComponent)

        let alert = NSAlert()
        alert.messageText = "Move Typer to the Applications folder?"
        alert.informativeText = translocated
            ? "Typer is running from a temporary read-only copy. Moving it to your Applications "
                + "folder lets updates and permissions stick. Typer will relaunch from there."
            : "Typer works best from the Applications folder — updates and permissions stick, and "
                + "macOS stops re-asking for access. Typer will relaunch from there."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Move to Applications Folder")
        alert.addButton(withTitle: "Do Not Move")
        guard alert.runModal() == .alertFirstButtonReturn else {
            // User declined — carry on from the current location, then offer the model upgrade.
            maybeOfferRecommendedModel()
            return
        }

        do {
            try fm.createDirectory(at: appsDir, withIntermediateDirectories: true)
            // Replace any older copy already sitting at the destination so the relaunch picks up
            // this build rather than a stale one.
            if fm.fileExists(atPath: dest.path) {
                // Don't clobber the very bundle we're running (non-translocated edge: dest == self).
                if dest.standardizedFileURL != bundleURL.standardizedFileURL {
                    try fm.removeItem(at: dest)
                }
            }
            if dest.standardizedFileURL != bundleURL.standardizedFileURL {
                // A translocated source lives on a read-only path, so copy (don't move) into place;
                // the translocated copy is reaped by the system. For a normal Downloads run a copy
                // is still safe and leaves the original for the user to trash.
                try fm.copyItem(at: bundleURL, to: dest)
            }
        } catch {
            log("LetsMove: copy to \(dest.path) failed — \(error.localizedDescription)")
            let fail = NSAlert()
            fail.messageText = "Couldn’t move Typer"
            fail.informativeText = "Typer couldn’t copy itself into the Applications folder "
                + "(\(error.localizedDescription)). You can move it manually in Finder. Typer will "
                + "keep running from here for now."
            fail.alertStyle = .warning
            fail.addButton(withTitle: "OK")
            fail.runModal()
            maybeOfferRecommendedModel()
            return
        }

        log("LetsMove: relaunching from \(dest.path)")
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: dest, configuration: config) { _, err in
            DispatchQueue.main.async {
                if let err {
                    log("LetsMove: relaunch failed — \(err.localizedDescription)")
                    // Relaunch failed: don't quit (the user would be left with nothing running).
                    self.maybeOfferRecommendedModel()
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
