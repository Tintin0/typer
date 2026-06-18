import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

extension TyperApp {
    func setupMenu() {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenu.delegate = self           // repopulate fresh each time it opens
        statusItem.menu = statusMenu
        updateStatusTitle()
        rebuildMenu()
    }

    // The menu-bar badge: a keyboard icon (renders reliably; a text-only status item
    // can collapse to zero width / be impossible to spot) plus the running count of
    // completions taken.
    func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        if button.image == nil {
            let img = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Typer")
            img?.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeading
        }
        button.title = cfg.enabled ? " \(stats.accepted)" : " ⏸"
    }

    // NSMenuDelegate: rebuild on open so stats/toggles are always current without
    // rebuilding the whole menu on every suggestion.
    func menuNeedsUpdate(_ menu: NSMenu) { if menu === statusMenu { rebuildMenu() } }

    func disabledItem(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); i.isEnabled = false; return i
    }

    func toggleItem(_ title: String, key: String, value: Bool) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(toggleSetting(_:)), keyEquivalent: "")
        i.state = value ? .on : .off
        i.representedObject = key
        i.target = self
        return i
    }

    func rebuildMenu() {
        let menu = statusMenu
        menu.removeAllItems()
        let model = (LlamaClient.findModel(cfg).map { ($0 as NSString).lastPathComponent }) ?? "no model"
        menu.addItem(disabledItem("Typer — \(cfg.enabled ? "on" : "paused")"))
        menu.addItem(disabledItem("Model: \(model)"))
        // typer-1 rollout status (only when a candidate model is actually present).
        if let rollout = router?.statusSummary() { menu.addItem(disabledItem(rollout)) }
        menu.addItem(.separator())
        for fact in funFacts() { menu.addItem(disabledItem(fact)) }
        menu.addItem(.separator())
        menu.addItem(disabledItem("Shown \(numberFormatted(stats.shown)) · Accepted \(stats.acceptRate)% · Learned \(styleMemory.sentenceCount()) sentences"))
        var personalization = "Vocabulary: \(numberFormatted(lexicon.wordCount())) words"
        if let s = feedback.summary() { personalization += " · \(s)" }
        menu.addItem(disabledItem(personalization))
        menu.addItem(.separator())

        menu.addItem(toggleItem("Enabled", key: "enabled", value: cfg.enabled))
        menu.addItem(toggleItem("Completions", key: "completion_enabled", value: cfg.completionEnabled))
        menu.addItem(toggleItem("Typo correction", key: "typo_correction_enabled", value: cfg.typoEnabled))

        // Per-app disable for the app currently being typed in.
        let (curBundle, curName) = currentAppBundleAndName()
        if !curBundle.isEmpty, curBundle != "no.bundle" {
            let item = NSMenuItem(title: "Disable in \(curName)", action: #selector(toggleDisableCurrentApp), keyEquivalent: "")
            item.state = cfg.disabledApps.contains(curBundle) ? .on : .off
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(toggleItem("Skip terminal apps", key: "disable_in_terminals", value: cfg.disableInTerminals))
        let batt = toggleItem("Battery saver", key: "battery_saver", value: cfg.batterySaver)
        if cfg.batterySaver && PowerState.shared.saving { batt.title = "Battery saver (throttling now)" }
        menu.addItem(batt)
        menu.addItem(.separator())

        let ctx = NSMenu()
        ctx.addItem(toggleItem("Window text", key: "window_context_enabled", value: cfg.windowContextEnabled))
        ctx.addItem(toggleItem("Clipboard", key: "clipboard_context_enabled", value: cfg.clipboardContextEnabled))
        ctx.addItem(toggleItem("Screen OCR (noisy)", key: "screen_context_enabled", value: cfg.screenContextEnabled))
        ctx.addItem(toggleItem("Screenshot caret (terminals; battery-heavy)", key: "screenshot_caret_enabled", value: cfg.screenshotCaretEnabled))
        let topic = toggleItem("Remember what I read (\(topicMemory.count()))", key: "topic_memory_enabled", value: cfg.topicMemoryEnabled)
        ctx.addItem(topic)
        ctx.addItem(toggleItem("Learn my style", key: "style_memory_enabled", value: cfg.styleMemoryEnabled))
        ctx.addItem(toggleItem("Learn my vocabulary", key: "lexicon_enabled", value: cfg.lexiconEnabled))
        ctx.addItem(toggleItem("Adapt to my accepts", key: "adaptive_suggestions", value: cfg.adaptiveSuggestions))
        let ctxItem = NSMenuItem(title: "Context sources", action: nil, keyEquivalent: ""); ctxItem.submenu = ctx
        menu.addItem(ctxItem)
        // Opt-in local training-data capture: records (context → suggestion, accepted?)
        // to train a local model later. Off by default; stays on this Mac. Enabling it
        // shows a one-time explanation of exactly what is stored (see confirmTrainingCapture).
        menu.addItem(toggleItem("Record my typing to train a local model (\(trainingLog.count()))", key: "training_log_enabled", value: cfg.trainingLogEnabled))
        if cfg.trainingLogEnabled, trainingLog.count() > 0 {
            menu.addItem(NSMenuItem(title: "Inspect training data…", action: #selector(openTrainingData), keyEquivalent: ""))
        }
        if router?.candidateAvailable == true {
            menu.addItem(NSMenuItem(title: "Reset typer-1 rollout", action: #selector(resetRollout), keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem(title: "Clear Learned Style", action: #selector(clearStyle), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reset All Data…", action: #selector(resetData), keyEquivalent: ""))
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Open Config…", action: #selector(openConfig), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Log…", action: #selector(openLog), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Typer", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil && item.target == nil { item.target = self }
        updateStatusTitle()
    }

    func configURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/typer/config.toml")
    }

    // Persist a single key=value into config.toml (replacing the line or appending).
    func writeConfig(_ key: String, _ value: String) {
        let url = configURL()
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found = false
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(key), t.dropFirst(key.count).trimmingCharacters(in: .whitespaces).first == "=" {
                lines[i] = "\(key) = \(value)"; found = true; break
            }
        }
        if !found { lines.append("\(key) = \(value)") }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    @objc func toggleSetting(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let v = sender.state != .on
        switch key {
        case "enabled": cfg.enabled = v; if !v { clearSuggestion() }
        case "completion_enabled": cfg.completionEnabled = v
        case "typo_correction_enabled": cfg.typoEnabled = v
        case "window_context_enabled": cfg.windowContextEnabled = v
        case "clipboard_context_enabled": cfg.clipboardContextEnabled = v
        case "screen_context_enabled": cfg.screenContextEnabled = v
        case "screenshot_caret_enabled": cfg.screenshotCaretEnabled = v
        case "style_memory_enabled": cfg.styleMemoryEnabled = v
        case "lexicon_enabled": cfg.lexiconEnabled = v
        case "adaptive_suggestions": cfg.adaptiveSuggestions = v
        case "training_log_enabled":
            // Turning capture ON shows a one-time explanation of what gets stored; if the
            // user backs out, leave it off and don't persist.
            if v, !confirmTrainingCapture() { rebuildMenu(); return }
            cfg.trainingLogEnabled = v
        case "battery_saver": cfg.batterySaver = v
        case "topic_memory_enabled":
            cfg.topicMemoryEnabled = v
            if v, !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
            startTopicTimer()
        default: break
        }
        writeConfig(key, v ? "true" : "false")
        log("toggle \(key)=\(v)")
        rebuildMenu()
    }

    @objc func openConfig() { NSWorkspace.shared.open(configURL()) }
    @objc func openLog() { NSWorkspace.shared.open(typerLogURL) }

    @objc func openTrainingData() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/typer/training.jsonl")
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
    }

    // One-time explanation shown before training capture is enabled. Spells out exactly
    // what is stored, that it never leaves the Mac, the secret-skipping safeguards, and
    // how to inspect or erase it — the consent step the data's sensitivity warrants.
    func confirmTrainingCapture() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Record your typing to train a local model?"
        alert.informativeText = """
        Typer will save the text right before your cursor and each suggestion (plus whether you used it) to a file on THIS Mac — ~/Library/Application Support/typer/training.jsonl. It never leaves your computer; it exists only to train a local autocomplete model.

        What you type can include private things, so capture is skipped in password fields, password managers, and disabled apps, and any line that looks like a password, code, key, path, or email is dropped automatically. You can inspect the file, turn this off anytime, or erase it with “Reset All Data.”
        """
        alert.addButton(withTitle: "Record Locally")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc func toggleDisableCurrentApp() {
        let (bundle, _) = currentAppBundleAndName()
        guard !bundle.isEmpty, bundle != "no.bundle" else { return }
        if cfg.disabledApps.contains(bundle) { cfg.disabledApps.remove(bundle) } else { cfg.disabledApps.insert(bundle) }
        writeConfig("disabled_apps", cfg.disabledApps.sorted().joined(separator: ","))
        if isAppDisabled() { clearSuggestion() }
        rebuildMenu()
    }

    @objc func resetData() {
        let alert = NSAlert()
        alert.messageText = "Reset all Typer data?"
        alert.informativeText = "Clears your learned writing style, vocabulary, suggestion feedback, remembered on-screen topics, saved training data, and all stats, returning Typer to a fresh state. Your settings are kept. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        styleMemory.clear()
        topicMemory.clear()
        lexicon.clear()
        feedback.clear()
        router.reset()
        trainingLog.clear()
        stats = TyperStats(); stats.save()
        buffer = ""; buffersByApp.removeAll(); lastInputByApp.removeAll()
        lexiconWatermark.removeAll()
        cachedBackground = ""; lastTrailing = ""
        clearSuggestion()
        updateStatusTitle()
        log("user reset all data")
    }

    @objc func clearStyle() {
        styleMemory.clear()
        log("cleared learned style")
        rebuildMenu()
    }

    // Restart typer-1's progressive rollout from the starting share (keeps the model,
    // forgets its accumulated accept/reject history and earned share).
    @objc func resetRollout() {
        router.reset()
        log("reset typer-1 rollout")
        rebuildMenu()
    }

    @objc func quit() { stats.save(); NSApp.terminate(nil) }
}
