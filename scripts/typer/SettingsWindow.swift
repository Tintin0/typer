import AppKit
import Combine
import Foundation
import SwiftUI

// Real preferences window (#15). Modeled on OnboardingController's controller + SwiftUI-host
// pattern. Wave 0 ships the shell: a window controller, a SwiftUI host, the shared
// SliderRow / StepperRow / SegmentedRow components, an empty sectioned body, and the
// `openSettings()` entry point wired to a menu item. Wave 2A fills the section content
// (snooze #3, length #9, personalization #10, per-app instructions #1, privacy #15).
//
// The window reads/writes the same `cfg` + `writeConfig` the menu uses, so settings
// round-trip through config.toml; per-app overrides round-trip through OverrideStore's JSON
// sidecar. SettingsModel is the bridge the SwiftUI views bind to.

final class SettingsModel: ObservableObject {
    weak var app: TyperApp?

    // Mirror of cfg, published so the SwiftUI rows stay live. Wave 2A binds the controls
    // that exist; W0 just seeds the values so the bindings compile and round-trip.
    @Published var personalizationStrength: Double = 0
    @Published var maxCompletionWords: Int = 7
    @Published var showSuggestedFixes = true
    @Published var suppressCompletionOnTypoSuspected = false
    @Published var emojiCompletionsEnabled = false
    @Published var emojiSearchEnabled = false
    @Published var emojiSkinTone = 0
    @Published var midLineCompletionsEnabled = true
    @Published var trainingLogEnabled = false

    // Context controls (moved out of the menu-bar popover into Settings).
    @Published var windowContext = true
    @Published var clipboardContext = true
    @Published var screenContext = false
    @Published var screenshotCaret = false
    @Published var topicMemory = false
    @Published var disableInTerminals = false
    @Published var batterySaver = true
    @Published var grammarEnabled = false
    // Personalization master: one switch for the three live-learning channels (style +
    // vocabulary + accept-adaptation). Reflects whether any is on; setting drives all three.
    @Published var learnFromWriting = true

    // Completion-length bucket index (#9): 0…4 over Short/Medium/Long/Very Long/Ultra Long.
    // Derived from maxCompletionWords on load; writing it back maps the bucket → a word cap.
    @Published var completionLengthBucket = 2

    // Per-app custom instructions editor (#1). The user picks a bundle to edit; the resolved
    // (inherited) view and the user's own override are surfaced side by side.
    @Published var perAppBundles: [AppRow] = []        // apps offered in the picker
    @Published var selectedBundle = ""                 // bundle currently being edited ("" = none)
    @Published var customInstructionsDraft = ""        // the editable text for selectedBundle
    @Published var inheritedInstructions = ""          // resolved-without-user view (for "inherited")

    // Denylist editor (#15 privacy). The user's per-app completion overrides as on/off rows.
    @Published var disabledAppBundles: [String] = []

    struct AppRow: Identifiable, Hashable {
        var id: String { bundle }
        let bundle: String
        let name: String
    }

    // Pull current values from the app's cfg.
    func load() {
        guard let cfg = app?.cfg else { return }
        personalizationStrength = cfg.personalizationStrength
        maxCompletionWords = cfg.maxCompletionWords
        completionLengthBucket = SettingsModel.bucket(forWords: cfg.maxCompletionWords)
        showSuggestedFixes = cfg.showSuggestedFixes
        suppressCompletionOnTypoSuspected = cfg.suppressCompletionOnTypoSuspected
        emojiCompletionsEnabled = cfg.emojiCompletionsEnabled
        emojiSearchEnabled = cfg.emojiSearchEnabled
        emojiSkinTone = cfg.emojiSkinTone
        midLineCompletionsEnabled = cfg.midLineCompletionsEnabled
        trainingLogEnabled = cfg.trainingLogEnabled
        windowContext = cfg.windowContextEnabled
        clipboardContext = cfg.clipboardContextEnabled
        screenContext = cfg.screenContextEnabled
        screenshotCaret = cfg.screenshotCaretEnabled
        topicMemory = cfg.topicMemoryEnabled
        disableInTerminals = cfg.disableInTerminals
        batterySaver = cfg.batterySaver
        grammarEnabled = cfg.grammarEnabled
        learnFromWriting = cfg.styleMemoryEnabled || cfg.lexiconEnabled || cfg.adaptiveSuggestions
        disabledAppBundles = cfg.disabledApps.sorted()
        reloadPerAppList()
    }

    // One switch for all three live-learning channels (consolidates the old menu toggles).
    func setLearnFromWriting(_ v: Bool) {
        app?.setToggle(key: "style_memory_enabled", on: v)
        app?.setToggle(key: "lexicon_enabled", on: v)
        app?.setToggle(key: "adaptive_suggestions", on: v)
        load()
    }

    // MARK: Completion length (#9)

    // 5 buckets → representative word caps. Token caps (≈ words × 1.6) are applied downstream
    // in the completion path (W2B); here we only persist the word cap the bucket represents.
    static let lengthWordCaps = [2, 4, 7, 10, 15]
    static let lengthLabels = ["Short", "Medium", "Long", "Very Long", "Ultra Long"]
    static let lengthSubtitles = ["~1–2 words", "~2–4 words", "~4–7 words", "~7–10 words", "~10–15 words"]

    static func bucket(forWords w: Int) -> Int {
        // Snap to the nearest bucket cap so a hand-edited config still lands on a stop.
        var best = 0, bestDist = Int.max
        for (i, cap) in lengthWordCaps.enumerated() {
            let d = abs(cap - w)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }

    func setLengthBucket(_ i: Int) {
        let idx = min(max(i, 0), SettingsModel.lengthWordCaps.count - 1)
        setInt("max_completion_words", SettingsModel.lengthWordCaps[idx])
    }

    // MARK: Per-app custom instructions (#1) + denylist (#15)

    // Build the app list offered in the per-app editor: the frontmost app (if any), every app
    // with an existing override or completion-disable, deduplicated by bundle and sorted by name.
    func reloadPerAppList() {
        var rows: [String: String] = [:]      // bundle → display name
        if let app {
            let (b, n) = app.currentAppBundleAndName()
            if !b.isEmpty, b != "no.bundle", b != "local.typer.menubar" { rows[b] = n.isEmpty ? b : n }
        }
        for b in OverrideStore.shared.apps.keys { rows[b, default: nameForBundle(b)] = rows[b] ?? nameForBundle(b) }
        for b in (app?.cfg.disabledApps ?? []) { rows[b, default: nameForBundle(b)] = rows[b] ?? nameForBundle(b) }
        perAppBundles = rows.map { AppRow(bundle: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // Keep a valid selection.
        if selectedBundle.isEmpty || !perAppBundles.contains(where: { $0.bundle == selectedBundle }) {
            selectBundle(perAppBundles.first?.bundle ?? "")
        } else {
            selectBundle(selectedBundle)
        }
    }

    // Best-effort human name for a bundle id we don't have a live app for.
    func nameForBundle(_ bundle: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundle
    }

    func selectBundle(_ bundle: String) {
        selectedBundle = bundle
        guard !bundle.isEmpty else { customInstructionsDraft = ""; inheritedInstructions = ""; return }
        customInstructionsDraft = OverrideStore.shared.userApp(bundle).customInstructions ?? ""
        // "Inherited" = what would apply if the user had no per-app instructions: the in-code
        // default for this bundle (most apps: none).
        inheritedInstructions = OverrideStore.defaults[bundle]?.customInstructions ?? ""
    }

    // Persist the edited per-app instructions through the override sidecar. Empty clears the row.
    func saveCustomInstructions() {
        guard !selectedBundle.isEmpty else { return }
        OverrideStore.shared.setCustomInstructions(customInstructionsDraft, forBundle: selectedBundle)
        reloadPerAppList()
    }

    // Whether the selected app currently has completions suppressed via cfg.disabledApps.
    func isBundleDisabled(_ bundle: String) -> Bool { disabledAppBundles.contains(bundle) }

    func setBundleDisabled(_ bundle: String, _ disabled: Bool) {
        guard let app, !bundle.isEmpty else { return }
        if disabled { app.cfg.disabledApps.insert(bundle) } else { app.cfg.disabledApps.remove(bundle) }
        app.writeConfig("disabled_apps", app.cfg.disabledApps.sorted().joined(separator: ","))
        app.applyDisabledAppsChange()
        load()
    }

    func resetAllData() { app?.resetData(); load() }

    // Setters routing through the app's typed config setters (which persist via writeConfig).
    func setDouble(_ key: String, _ v: Double) { app?.setDouble(key: key, value: v); load() }
    func setInt(_ key: String, _ v: Int) { app?.setInt(key: key, value: v); load() }
    func setToggle(_ key: String, _ v: Bool) { app?.setToggle(key: key, on: v); load() }

    func boolBinding(_ get: @escaping (SettingsModel) -> Bool, _ key: String) -> Binding<Bool> {
        Binding(get: { get(self) }, set: { self.setToggle(key, $0) })
    }
    func intBinding(_ get: @escaping (SettingsModel) -> Int, _ key: String) -> Binding<Int> {
        Binding(get: { get(self) }, set: { self.setInt(key, $0) })
    }
    func doubleBinding(_ get: @escaping (SettingsModel) -> Double, _ key: String) -> Binding<Double> {
        Binding(get: { get(self) }, set: { self.setDouble(key, $0) })
    }
}

// Owns the settings NSWindow; reused if already open.
final class SettingsController {
    static let shared = SettingsController()
    private var window: NSWindow?
    let model = SettingsModel()

    func show(app: TyperApp) {
        model.app = app
        model.load()
        if let win = window {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: SettingsView(model: model))
        let win = NSWindow(contentViewController: host)
        win.title = "Typer Settings"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 480, height: 560))
        win.center()
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
}

extension TyperApp {
    // Entry point used by the menu's "Open Settings…" item (and onboarding, later).
    func openSettings() { SettingsController.shared.show(app: self) }
}

// MARK: - View

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    suggestionsSection
                    snoozeSection
                    personalizationSection
                    contextSection
                    perAppSection
                    privacySection
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 480, height: 560)
        .onAppear { model.load() }
    }

    // MARK: Suggestions (#9 length, #8 fixes)

    private var suggestionsSection: some View {
        SettingsSection(title: "Suggestions") {
            SegmentedRow(
                title: "Completion length",
                subtitle: SettingsModel.lengthSubtitles[model.completionLengthBucket],
                options: SettingsModel.lengthLabels,
                selection: Binding(
                    get: { model.completionLengthBucket },
                    set: { model.setLengthBucket($0) }))
            Toggle("Show suggested fixes",
                   isOn: model.boolBinding({ $0.showSuggestedFixes }, "show_suggested_fixes"))
                .toggleStyle(.switch).font(.system(size: 13))
            Toggle("Don't extend a word that looks misspelled",
                   isOn: model.boolBinding({ $0.suppressCompletionOnTypoSuspected }, "suppress_completion_on_typo_suspected"))
                .toggleStyle(.switch).font(.system(size: 13))
        }
    }

    // MARK: Snooze (#3)

    private var snoozeSection: some View {
        SettingsSection(title: "Snooze") {
            if let r = model.app?.globalSnoozeRemaining() {
                HStack {
                    Text("All completions paused — \(TyperApp.formatSnoozeRemaining(r)) left")
                        .font(.system(size: 13)).foregroundStyle(.orange)
                    Spacer()
                    Button("Resume") { model.app?.resumeCompletions(); model.objectWillChange.send() }
                }
            } else {
                HStack(spacing: 8) {
                    Text("Pause all completions for").font(.system(size: 13))
                    Spacer()
                    ForEach([5, 15, 60], id: \.self) { mins in
                        Button(mins == 60 ? "1h" : "\(mins)m") {
                            model.app?.snoozeAll(minutes: mins); model.objectWillChange.send()
                        }
                    }
                }
                Text("A snooze is session-only — it clears when completions resume or Typer restarts.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Personalization (#10)

    private var personalizationSection: some View {
        SettingsSection(title: "Personalization") {
            Toggle("Learn from my writing", isOn: Binding(
                get: { model.learnFromWriting },
                set: { model.setLearnFromWriting($0) }))
                .toggleStyle(.switch).font(.system(size: 13))
            Text("Picks up your style, vocabulary, and what you accept — all on-device.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            SliderRow(
                title: "Personalization strength",
                subtitle: "Leans suggestions toward the words and phrases you use most.",
                value: model.doubleBinding({ $0.personalizationStrength }, "personalization_strength"),
                range: 0...1, step: 0.05,
                format: { $0 <= 0.001 ? "Off" : String(format: "%.0f%%", $0 * 100) })
        }
    }

    // MARK: Context (moved out of the menu-bar popover)

    private func ctxToggle(_ title: String, _ get: @escaping (SettingsModel) -> Bool, _ key: String) -> some View {
        Toggle(title, isOn: model.boolBinding(get, key)).toggleStyle(.switch).font(.system(size: 13))
    }

    private var contextSection: some View {
        SettingsSection(title: "Context") {
            ctxToggle("Window text", { $0.windowContext }, "window_context_enabled")
            ctxToggle("Clipboard", { $0.clipboardContext }, "clipboard_context_enabled")
            ctxToggle("Screen OCR (filtered)", { $0.screenContext }, "screen_context_enabled")
            ctxToggle("Screenshot caret (terminals; battery-heavy)", { $0.screenshotCaret }, "screenshot_caret_enabled")
            ctxToggle("Remember what I read", { $0.topicMemory }, "topic_memory_enabled")
            ctxToggle("Skip terminal apps", { $0.disableInTerminals }, "disable_in_terminals")
            ctxToggle("Battery saver", { $0.batterySaver }, "battery_saver")
            ctxToggle("Grammar (experimental)", { $0.grammarEnabled }, "grammar_enabled")
        }
    }

    // MARK: Per-app custom instructions (#1)

    private var perAppSection: some View {
        SettingsSection(title: "Per-app instructions") {
            if model.perAppBundles.isEmpty {
                Text("Switch to an app, then reopen Settings to add instructions for it.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Picker("App", selection: Binding(
                    get: { model.selectedBundle },
                    set: { model.selectBundle($0) })) {
                    ForEach(model.perAppBundles) { row in
                        Text(row.name).tag(row.bundle)
                    }
                }
                .pickerStyle(.menu).font(.system(size: 13))

                if !model.inheritedInstructions.isEmpty {
                    Text("Inherited: \(model.inheritedInstructions)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("No inherited instructions for this app.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                TextEditor(text: Binding(
                    get: { model.customInstructionsDraft },
                    set: { model.customInstructionsDraft = $0 }))
                    .font(.system(size: 12))
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))

                HStack {
                    Text(model.customInstructionsDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "Using inherited / global tone." : "Overridden for this app.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") { model.saveCustomInstructions() }
                }
            }
        }
    }

    // MARK: Privacy & data (#15)

    private var privacySection: some View {
        SettingsSection(title: "Privacy & Data") {
            Toggle("Record my typing to train a local model",
                   isOn: Binding(
                    get: { model.trainingLogEnabled },
                    set: { model.setToggle("training_log_enabled", $0) }))
                .toggleStyle(.switch).font(.system(size: 13))
            Text("Saved only on this Mac; skipped in password fields and managers. Never uploaded.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                if model.trainingLogEnabled {
                    Button("Inspect training data…") { model.app?.openTrainingData() }
                        .font(.system(size: 12))
                }
                Button("Clear learned style") { model.app?.clearStyle() }
                    .font(.system(size: 12))
            }
            .padding(.top, 2)

            if !model.disabledAppBundles.isEmpty {
                Text("Completions disabled in").font(.system(size: 12, weight: .medium)).padding(.top, 4)
                ForEach(model.disabledAppBundles, id: \.self) { bundle in
                    HStack {
                        Text(model.nameForBundle(bundle)).font(.system(size: 12))
                        Spacer()
                        Button("Enable") { model.setBundleDisabled(bundle, false) }
                            .font(.system(size: 11))
                    }
                }
            }

            Button(role: .destructive) { model.resetAllData() } label: {
                Text("Reset all data…").foregroundStyle(.red)
            }
            .padding(.top, 6)
        }
    }
}

// A titled group of rows.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold)).tracking(0.5)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shared rows (built once in W0, consumed by W2A)

// A labelled slider with a live value readout. `format` renders the trailing value.
struct SliderRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double = 0.05
    var format: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13))
                    if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Spacer()
                Text(format(value)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

// A labelled integer stepper.
struct StepperRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...100
    var step: Int = 1
    var format: (Int) -> String = { "\($0)" }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(format(value)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            Stepper("", value: $value, in: range, step: step).labelsHidden()
        }
    }
}

// A labelled segmented picker over a fixed list of options. The bound value is the index.
struct SegmentedRow: View {
    let title: String
    var subtitle: String? = nil
    let options: [String]
    @Binding var selection: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Picker("", selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { i, label in
                    Text(label).tag(i)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}
