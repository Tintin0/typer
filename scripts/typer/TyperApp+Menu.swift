import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import SwiftUI
import Vision

extension TyperApp {
    func setupMenu() {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        let pop = NSPopover()
        pop.behavior = .transient           // dismiss on click-away
        pop.animates = true
        pop.contentViewController = NSHostingController(rootView: MenuRootView(model: menuModel))
        popover = pop
        updateStatusTitle()
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

    // Open/close the custom popover under the status item, snapshotting fresh state first.
    @objc func togglePopover(_ sender: Any?) {
        guard let pop = popover, let button = statusItem?.button else { return }
        if pop.isShown { pop.performClose(sender); return }
        menuModel.refresh()
        NSApp.activate(ignoringOtherApps: true)
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    // Snapshot everything the popover renders. The app stays the source of truth; the UI
    // just reads this on open and writes back through setToggle / performMenuAction.
    func menuSnapshot() -> MenuSnapshot {
        var s = MenuSnapshot()
        s.enabled = cfg.enabled
        s.completionEnabled = cfg.completionEnabled
        s.typoEnabled = cfg.typoEnabled

        let (curBundle, curName) = currentAppBundleAndName()
        if !curBundle.isEmpty, curBundle != "no.bundle" {
            s.hasCurrentApp = true; s.currentAppName = curName
            s.currentAppDisabled = cfg.disabledApps.contains(curBundle)
        }
        s.disableInTerminals = cfg.disableInTerminals
        s.batterySaver = cfg.batterySaver
        s.batteryThrottling = cfg.batterySaver && PowerState.shared.saving

        s.windowContext = cfg.windowContextEnabled
        s.clipboardContext = cfg.clipboardContextEnabled
        s.screenContext = cfg.screenContextEnabled
        s.screenshotCaret = cfg.screenshotCaretEnabled
        s.topicMemory = cfg.topicMemoryEnabled; s.topicCount = topicMemory.count()
        s.styleMemory = cfg.styleMemoryEnabled
        s.lexicon = cfg.lexiconEnabled
        s.adaptive = cfg.adaptiveSuggestions

        s.trainingEnabled = cfg.trainingLogEnabled; s.trainingCount = trainingLog.count()

        if let r = router?.raceState() {
            s.racing = true; s.aName = r.a; s.bName = r.b; s.aShare = r.aShare
            s.aReward = r.aReward; s.bReward = r.bReward; s.lockedName = r.lockedName
        } else if let r = router {
            s.singleModel = (r.nameA as NSString).deletingPathExtension
        }

        let w = stats.wordsCompleted, m = w / 40
        if w > 0 {
            s.statsLine1 = "\(numberFormatted(w)) words completed" + (m >= 1 ? " · ~\(numberFormatted(m)) min saved" : "")
        } else {
            s.statsLine1 = "No completions yet — start typing"
        }
        var l2 = "\(stats.acceptRate)% accepted · \(numberFormatted(lexicon.wordCount())) words learned"
        if stats.currentStreak > 0 { l2 = "\(stats.currentStreak)-day streak · " + l2 }
        s.statsLine2 = l2
        return s
    }

    // Apply one toggle from the popover (mirrors the old NSMenu toggleSetting, minus the
    // NSMenuItem). Training capture still shows its one-time consent sheet before enabling.
    func setToggle(key: String, on v: Bool) {
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
            if v, !confirmTrainingCapture() { return }   // user backed out → leave off
            cfg.trainingLogEnabled = v
        case "battery_saver": cfg.batterySaver = v
        case "topic_memory_enabled":
            cfg.topicMemoryEnabled = v
            if v, !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
            startTopicTimer()
        default: return
        }
        writeConfig(key, v ? "true" : "false")
        log("toggle \(key)=\(v)")
        updateStatusTitle()
    }

    // Route a popover button to its handler. Everything but the per-app toggle closes the
    // popover first so any file/sheet it opens isn't stuck behind it.
    func performMenuAction(_ a: MenuAction) {
        if a != .disableCurrentApp { popover?.performClose(nil) }
        switch a {
        case .config: openConfig()
        case .log: openLog()
        case .inspectTraining: openTrainingData()
        case .resetRace: resetRollout()
        case .clearStyle: clearStyle()
        case .resetAll: resetData()
        case .quit: quit()
        case .disableCurrentApp: toggleDisableCurrentApp()
        }
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
        updateStatusTitle()
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
        updateStatusTitle()
    }

    // Restart typer-1's progressive rollout from the starting share (keeps the model,
    // forgets its accumulated accept/reject history and earned share).
    @objc func resetRollout() {
        router.reset()
        log("reset model race")
        updateStatusTitle()
    }

    @objc func quit() { stats.save(); NSApp.terminate(nil) }
}
