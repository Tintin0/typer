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

    // Recommend a tier from installed RAM: 8 GB -> small, 16 GB -> medium, 32 GB+ -> large.
    // Onboarding highlights this so users pick a model their machine can actually run well.
    static func recommendedVariant() -> String {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        if gb >= 24 { return "l" }
        if gb >= 14 { return "m" }
        return "s"
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
            log("\(t.file) not present — downloading from \(t.url)")
            let dest = URL(fileURLWithPath: ModelRouter.tierPath(t))
            ModelDownloader.shared.download(urlString: t.url, to: dest) { [weak self] ok in
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

    // The tier currently being SERVED: falls back to "s" if a download tier was chosen but isn't
    // installed yet — what the menu's selected row and onboarding should reflect.
    func effectiveVariant() -> String {
        if let t = ModelRouter.tier(cfg.modelVariant) {
            return ModelRouter.tierInstalled(t.id) ? t.id : "s"
        }
        return "s"
    }
}
