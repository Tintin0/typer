import AppKit
import SwiftUI

// Custom menu-bar dropdown. Replaces the stock NSMenu with a SwiftUI popover so the panel can
// look like something we designed: a status dot, a model-preference bar, real switch toggles,
// and the rarely-touched controls tucked into collapsible sections instead of a flat wall of
// rows. The app stays the source of truth — MenuModel just snapshots state on open and routes
// toggles/actions back to TyperApp.

// What the popover needs to render, snapshotted from TyperApp each time it opens.
struct MenuSnapshot {
    var enabled = true
    var completionEnabled = true
    var typoEnabled = false

    // Behavior
    var hasCurrentApp = false
    var currentAppName = ""
    var currentAppDisabled = false
    var disableInTerminals = false
    var batterySaver = false
    var batteryThrottling = false

    // Context & learning
    var windowContext = false
    var clipboardContext = false
    var screenContext = false
    var screenshotCaret = false
    var topicMemory = false
    var topicCount = 0
    var styleMemory = false
    var lexicon = false
    var adaptive = false

    // Training & data
    var trainingEnabled = false
    var trainingCount = 0

    // Model race
    var racing = false
    var aName = "a"
    var bName = "b"
    var aShare = 0.5
    var aReward = 0.0
    var bReward = 0.0
    var lockedName: String?
    var singleModel = ""          // when not racing: the one model's name

    // Stats (no emoji, just signal)
    var statsLine1 = ""
    var statsLine2 = ""
}

enum MenuAction {
    case config, log, inspectTraining, resetRace, clearStyle, resetAll, quit, disableCurrentApp
}

final class MenuModel: ObservableObject {
    weak var app: TyperApp?
    @Published var snap = MenuSnapshot()

    func refresh() { if let app { snap = app.menuSnapshot() } }

    func bind(_ key: String, _ kp: KeyPath<MenuSnapshot, Bool>) -> Binding<Bool> {
        Binding(get: { self.snap[keyPath: kp] }, set: { self.app?.setToggle(key: key, on: $0); self.refresh() })
    }
    func toggleApp() { app?.setToggle(key: "enabled", on: !snap.enabled); refresh() }
    func toggleCurrentApp() { app?.performMenuAction(.disableCurrentApp); refresh() }
    func action(_ a: MenuAction) { app?.performMenuAction(a); refresh() }
}

// MARK: - Views

struct MenuRootView: View {
    @ObservedObject var model: MenuModel
    private var s: MenuSnapshot { model.snap }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            sep
            if s.racing { modelCard; sep } else if !s.singleModel.isEmpty { singleModelRow; sep }
            stats
            sep
            VStack(spacing: 0) {
                ToggleRow(title: "Completions", isOn: model.bind("completion_enabled", \.completionEnabled))
                ToggleRow(title: "Typo correction", isOn: model.bind("typo_correction_enabled", \.typoEnabled))
            }
            sep
            sections
            sep
            footer
        }
        .frame(width: 308)
        .padding(.vertical, 8)
    }

    private var sep: some View { Divider().opacity(0.45).padding(.vertical, 6) }

    private var header: some View {
        HStack(spacing: 9) {
            Circle().fill(s.enabled ? Color.green : Color.red)
                .frame(width: 9, height: 9)
                .shadow(color: (s.enabled ? Color.green : Color.red).opacity(0.6), radius: 3)
            Text("Typer").font(.system(size: 14, weight: .semibold))
            Text(s.enabled ? "on" : "paused").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Toggle("", isOn: Binding(get: { s.enabled }, set: { _ in model.toggleApp() }))
                .toggleStyle(.switch).tint(.green).labelsHidden().scaleEffect(0.85)
        }
        .padding(.horizontal, 14).padding(.top, 2)
    }

    private var singleModelRow: some View {
        HStack {
            Text("Model").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(s.singleModel).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }.padding(.horizontal, 14)
    }

    private var modelCard: some View {
        let aLeads = s.aShare >= 0.5
        let leader = s.lockedName ?? (aLeads ? s.aName : s.bName)
        let label = s.lockedName != nil ? "locked on \(leader)" : "\(leader) leading"
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Model preference").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(label).font(.caption.weight(.medium))
                    .foregroundStyle(s.lockedName != nil ? Color.green : Color.primary)
            }
            ShareBar(aShare: s.aShare, aLeads: aLeads, locked: s.lockedName != nil)
            HStack {
                Text("\(s.aName) \(pct(s.aShare))").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text("\(s.bName) \(pct(1 - s.aShare))").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 14)
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(s.statsLine1).font(.system(size: 11))
            Text(s.statsLine2).font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(.horizontal, 14)
    }

    private var sections: some View {
        VStack(spacing: 2) {
            MenuSection(title: "Behavior") {
                if s.hasCurrentApp {
                    ToggleRow(title: "Disable in \(s.currentAppName)",
                              isOn: Binding(get: { s.currentAppDisabled }, set: { _ in model.toggleCurrentApp() }))
                }
                ToggleRow(title: "Skip terminal apps", isOn: model.bind("disable_in_terminals", \.disableInTerminals))
                ToggleRow(title: s.batteryThrottling ? "Battery saver (throttling)" : "Battery saver",
                          isOn: model.bind("battery_saver", \.batterySaver))
            }
            MenuSection(title: "Context & learning") {
                ToggleRow(title: "Window text", isOn: model.bind("window_context_enabled", \.windowContext))
                ToggleRow(title: "Clipboard", isOn: model.bind("clipboard_context_enabled", \.clipboardContext))
                ToggleRow(title: "Screen OCR", subtitle: "noisy", isOn: model.bind("screen_context_enabled", \.screenContext))
                ToggleRow(title: "Screenshot caret", subtitle: "terminals; battery-heavy", isOn: model.bind("screenshot_caret_enabled", \.screenshotCaret))
                ToggleRow(title: "Remember what I read", subtitle: s.topicCount > 0 ? "\(s.topicCount) topics" : nil, isOn: model.bind("topic_memory_enabled", \.topicMemory))
                ToggleRow(title: "Learn my style", isOn: model.bind("style_memory_enabled", \.styleMemory))
                ToggleRow(title: "Learn my vocabulary", isOn: model.bind("lexicon_enabled", \.lexicon))
                ToggleRow(title: "Adapt to my accepts", isOn: model.bind("adaptive_suggestions", \.adaptive))
            }
            MenuSection(title: "Training & data") {
                ToggleRow(title: "Record my typing", subtitle: s.trainingCount > 0 ? "\(s.trainingCount) samples" : "trains a local model",
                          isOn: model.bind("training_log_enabled", \.trainingEnabled))
                if s.trainingEnabled, s.trainingCount > 0 {
                    ActionRow(title: "Inspect training data…") { model.action(.inspectTraining) }
                }
                if s.racing { ActionRow(title: "Reset model race") { model.action(.resetRace) } }
                ActionRow(title: "Clear learned style") { model.action(.clearStyle) }
                ActionRow(title: "Reset all data…", tint: .red) { model.action(.resetAll) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "gearshape", help: "Open config") { model.action(.config) }
            IconButton(symbol: "doc.plaintext", help: "Open log") { model.action(.log) }
            Spacer()
            Button(action: { model.action(.quit) }) {
                Text("Quit").font(.system(size: 12)).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
        }.padding(.horizontal, 12)
    }

    private func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
}

// A slim two-segment bar showing the share split; the leader is tinted, the loser muted.
private struct ShareBar: View {
    let aShare: Double
    let aLeads: Bool
    let locked: Bool
    var body: some View {
        GeometryReader { geo in
            let w = max(0, geo.size.width)
            let aw = max(2, min(w - 2, w * aShare))
            HStack(spacing: 2) {
                Capsule().fill(color(aLeads)).frame(width: aw - 1)
                Capsule().fill(color(!aLeads))
            }
        }
        .frame(height: 6)
    }
    private func color(_ leading: Bool) -> Color {
        leading ? (locked ? Color.green : Color.accentColor) : Color.secondary.opacity(0.35)
    }
}

private struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                if let subtitle { Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }
        .toggleStyle(.switch).tint(.green)
        .padding(.horizontal, 14).padding(.vertical, 3)
    }
}

private struct ActionRow: View {
    let title: String
    var tint: Color = .primary
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hover ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hover = $0 }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hover ? 0.1 : 0)))
        }
        .buttonStyle(.plain).help(help).onHover { hover = $0 }
    }
}

// A collapsible section with a chevron header; collapsed by default so the panel stays compact.
private struct MenuSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @State private var open = false
    var body: some View {
        VStack(spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.12)) { open.toggle() } }) {
                HStack {
                    Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary).rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 14).padding(.vertical, 5)
            }.buttonStyle(.plain)
            if open { VStack(spacing: 0) { content }.padding(.bottom, 4) }
        }
    }
}
