import AppKit
import Foundation

// Model-size switching (small typer-1 race ⇄ large typer-1l) at runtime: swap the ModelRouter
// in place, tearing down the old helper processes, with no app restart. The large model is
// fetched on demand the first time it's chosen.
extension TyperApp {
    // Human-facing labels for the three tiers (menu + onboarding).
    static func variantLabel(_ v: String) -> String {
        switch v {
        case "m": return "Medium · typer-1m (1.7B)"
        case "l": return "Large · typer-1l (4B)"
        default:  return "Small · typer-1s (0.6B)"
        }
    }

    // Recommend a tier from installed RAM AND performance-core count: pick the largest model whose
    // RAM floor and CPU-tier floor the machine clears (see ModelRouter.recommendedTier). Onboarding
    // highlights this so users pick a model their machine can actually run well — a 32 GB Mac with
    // few perf cores is steered to medium, not large, so latency stays usable.
    static func recommendedVariant() -> String {
        ModelRouter.recommendedTier().id
    }

    // Rebuild the router from the current cfg and warm it. Main-thread only (router is
    // main-thread state). The previous router's helper processes are killed after the swap so
    // the next generation spawns against the newly chosen model.
    func reloadModel() {
        let old = router
        router = ModelRouter(cfg: cfg)
        routedModelName = router.defaultName
        old?.shutdown()
        clearSuggestion()                       // any in-flight suggestion belonged to the old model
        if cfg.enabled, cfg.completionEnabled {
            DispatchQueue.global(qos: .utility).async { self.router.warmUp() }
        }
        updateStatusTitle()
        log("model reloaded: variant=\(cfg.modelVariant) serving=\(router.defaultName) large=\(router.isLarge)")
    }

    // Switch the user's model choice ("s" | "m" | "l"). Picking a download tier that isn't
    // present yet records the intent immediately, kicks off the on-demand fetch, and reloads
    // onto it once it lands; until then the small race keeps serving. Progress shows via
    // ModelDownloader. The menu/onboarding poll effectiveVariant() for what's actually served.
    func setModelVariant(_ variant: String) {
        let v = ["s", "m", "l"].contains(variant) ? variant : "s"
        guard v != cfg.modelVariant else { return }
        cfg.modelVariant = v
        writeConfig("model_variant", v)
        if let t = ModelRouter.tier(v), !ModelRouter.tierInstalled(v) {
            let dest = URL(fileURLWithPath: ModelRouter.tierPath(t))
            // Disk-space pre-check before we commit to the download: bail with a clear alert and
            // revert the selection so the menu/onboarding don't show a tier we can't fetch.
            guard ModelDownloader.hasRoomForDownload(of: t.sizeBytes, at: dest) else {
                let needGB = String(format: "%.1f",
                    Double(t.sizeBytes + ModelDownloader.diskMarginBytes) / 1_073_741_824.0)
                let freeGB = ModelDownloader.availableBytes(on: dest)
                    .map { String(format: "%.1f", Double($0) / 1_073_741_824.0) } ?? "unknown"
                log("download blocked for \(t.file): need \(needGB) GB free, have \(freeGB) GB")
                let alert = NSAlert()
                alert.messageText = "Not enough disk space for \(t.label)"
                alert.informativeText = "\(t.label) needs about \(needGB) GB free to download and install. "
                    + "You have \(freeGB) GB available. Free up some space and try again."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                cfg.modelVariant = "s"               // revert: we never started the fetch
                writeConfig("model_variant", "s")
                updateStatusTitle()
                return
            }
            log("\(t.file) not present — downloading from \(t.url)")
            ModelDownloader.shared.download(urlString: t.url, to: dest, expectedBytes: t.sizeBytes) { [weak self] ok in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if ok { log("downloaded -> \(t.file)"); self.reloadModel() }
                    else { log("download failed for \(t.file)") }
                }
            }
            return                                   // keep serving small until it lands
        }
        reloadModel()
    }

    // "A better model fits your Mac" notice (#11). When the hardware can comfortably run a larger
    // tier than the one currently served, offer to switch — once per recommended tier, so we never
    // nag. Shown shortly after launch (and re-checkable from onboarding). Honors the same disk
    // pre-check path as a manual switch via setModelVariant.
    func maybeOfferRecommendedModel() {
        guard let rec = ModelRouter.upgradeRecommendation(currentVariant: effectiveVariant()) else { return }
        let key = "typer.recommendedModelNoticeShown.\(rec.id)"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)

        let ram = ModelRouter.installedMemoryGB
        let alert = NSAlert()
        alert.messageText = "A better model fits your Mac"
        alert.informativeText = "Your Mac has \(ram) GB of memory and the cores to run \(rec.label) "
            + "well. It gives noticeably better suggestions. Switch now? (It downloads once, "
            + "about \(rec.approxMB) MB.)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Switch to \(rec.label)")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            setModelVariant(rec.id)
        }
    }

    // The tier currently being SERVED: falls back to "s" if a download tier was chosen but isn't
    // installed yet — what the menu's selected row and onboarding should reflect.
    func effectiveVariant() -> String {
        if let t = ModelRouter.tier(cfg.modelVariant) {
            return ModelRouter.tierInstalled(t.id) ? t.id : "s"
        }
        return "s"
    }
}
