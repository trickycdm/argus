import SwiftUI

/// First-run setup, styled as a Flight Deck preflight checklist: one fixed
/// pane, sections between hairlines, no paging, no animation (the design
/// system's animation budget is fully spent on the popover).
struct OnboardingView: View {
    @Bindable var model: OnboardingModel

    private struct EditorPreset: Identifiable {
        let label: String
        let appName: String   // LaunchServices name for `open -a`
        var id: String { appName }
    }

    private static let editorPresets: [EditorPreset] = [
        EditorPreset(label: "ZED", appName: "Zed"),
        EditorPreset(label: "VS CODE", appName: "Visual Studio Code"),
        EditorPreset(label: "CURSOR", appName: "Cursor"),
        EditorPreset(label: "XCODE", appName: "Xcode"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider
            editorSection
            divider
            terminalSection
            divider
            hooksSection
            divider
            notificationsSection
            divider
            alarmSection
            divider
            linearSection
            divider
            footer
        }
        .frame(width: 470)
        .background(Deck.bg)
        // The popover's dark-only modifier doesn't reach this window.
        .environment(\.colorScheme, .dark)
        .onAppear { model.refresh() }
    }

    private var divider: some View {
        Rectangle().fill(Deck.rowLine).frame(height: 1)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("ARGUS")
                    .font(Deck.display(15))
                    .kerning(3.2)
                    .foregroundStyle(Deck.text)
                Spacer()
                Text("FIRST-RUN SETUP")
                    .font(Deck.display(11))
                    .kerning(1.7)
                    .foregroundStyle(Deck.dim)
            }
            Text("THE HUNDRED-EYED WATCHMAN FOR YOUR CLAUDE CODE SESSIONS.")
                .font(Deck.label(13))
                .kerning(0.3)
                .foregroundStyle(Deck.muted)
            Text("PICK YOUR TOOLS — EVERYTHING CAN BE CHANGED LATER VIA THE GEAR.")
                .font(Deck.label(13))
                .kerning(0.3)
                .foregroundStyle(Deck.muted)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 13)
    }

    private var editorSection: some View {
        section("EDITOR") {
            HStack(spacing: 6) {
                ForEach(Self.editorPresets) { preset in
                    SelectChip(label: preset.label,
                               selected: model.editor == preset.appName) {
                        model.editor = preset.appName
                    }
                    .help("Open sessions with `open -a \(preset.appName)`")
                }
            }
            underlinedField("OTHER APP NAME", text: $model.editor)
                .help("Any app name LaunchServices can resolve via `open -a`")
        }
    }

    private var terminalSection: some View {
        section("TERMINAL") {
            HStack(spacing: 6) {
                SelectChip(label: "ITERM2", selected: model.terminal == .iterm) {
                    model.terminal = .iterm
                }
                .help("Focus and resume tabs via iTerm2 AppleScript")
                SelectChip(label: "GHOSTTY", selected: model.terminal == .ghostty) {
                    model.terminal = .ghostty
                }
                .help("Requires Ghostty 1.3+ with macos-applescript enabled")
            }
            Text("EACH SESSION'S TERMINAL IS AUTO-DETECTED — THIS COVERS THE ONES THAT CAN'T BE.")
                .font(Deck.label(11))
                .kerning(0.4)
                .foregroundStyle(Deck.dim)
        }
    }

    private var hooksSection: some View {
        section("CAPTURE HOOKS", chip: hookChip) {
            Text("A HOOK IN ~/.CLAUDE/SETTINGS.JSON REPORTS SESSION EVENTS — WITHOUT IT ARGUS SEES NOTHING.")
                .font(Deck.label(11))
                .kerning(0.4)
                .foregroundStyle(Deck.dim)
            Text("SESSIONS ALREADY RUNNING AREN'T TRACKED — RESTART THEM TO MONITOR.")
                .font(Deck.label(11))
                .kerning(0.4)
                .foregroundStyle(Deck.muted)
            if model.hookState == .missing {
                if model.installerPath != nil {
                    HStack(spacing: 8) {
                        ChipButton(label: model.installerRunning ? "INSTALLING…" : "INSTALL HOOKS") {
                            model.installHooks()
                        }
                        .disabled(model.installerRunning)
                        .help("Runs scripts/install-hooks.sh — backs up settings.json first")
                        recheckButton
                    }
                } else {
                    Text(model.installCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Deck.muted)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        ChipButton(label: "COPY COMMAND") { model.copyInstallCommand() }
                            .help("Copy the install command to run in a terminal")
                        recheckButton
                    }
                }
            }
            if let error = model.hookError {
                Text(error.uppercased())
                    .font(Deck.label(11))
                    .kerning(0.4)
                    .foregroundStyle(Deck.amber)
                    .lineLimit(2)
            }
        }
    }

    private var recheckButton: some View {
        ChipButton(label: "RECHECK", color: Deck.muted) { model.refresh() }
            .help("Re-read ~/.claude/settings.json")
    }

    private var hookChip: StepChip {
        switch model.hookState {
        case .installed: StepChip(word: "OK", color: Deck.green)
        case .missing: StepChip(word: "MISSING", color: Deck.amber)
        case nil: StepChip(word: "CHECKING", color: Deck.dim)
        }
    }

    private var notificationsSection: some View {
        section("NOTIFICATIONS", chip: notificationChip) {
            Text("ALERTS WHEN A SESSION BLOCKS ON YOU, FINISHES WORK, OR NEARS ITS CONTEXT ALARM.")
                .font(Deck.label(11))
                .kerning(0.4)
                .foregroundStyle(Deck.dim)
            switch model.notifications {
            case .notDetermined:
                ChipButton(label: "ENABLE NOTIFICATIONS") { model.enableNotifications() }
                    .help("Shows the macOS notification permission prompt")
            case .denied:
                Text("ENABLE IN SYSTEM SETTINGS → NOTIFICATIONS → ARGUS.")
                    .font(Deck.label(11))
                    .kerning(0.4)
                    .foregroundStyle(Deck.muted)
            case .unavailable:
                Text("NOTIFICATIONS NEED THE BUNDLED APP — BUILD WITH SCRIPTS/BUNDLE.SH.")
                    .font(Deck.label(11))
                    .kerning(0.4)
                    .foregroundStyle(Deck.muted)
            case .checking, .granted:
                EmptyView()
            }
        }
    }

    private var notificationChip: StepChip {
        switch model.notifications {
        case .checking: StepChip(word: "CHECKING", color: Deck.dim)
        case .unavailable: StepChip(word: "N/A", color: Deck.dim)
        case .notDetermined: StepChip(word: "PENDING", color: Deck.dim)
        case .granted: StepChip(word: "GRANTED", color: Deck.green)
        case .denied: StepChip(word: "DENIED", color: Deck.amber)
        }
    }

    private var alarmSection: some View {
        section("CONTEXT ALARM") {
            HStack(spacing: 10) {
                ChipButton(label: "−", color: Deck.muted) {
                    model.contextAlarm = (model.contextAlarm - 5)
                        .clamped(to: ContextAlarm.clampPercent)
                }
                .help("Lower the alarm threshold")
                Text("\(model.contextAlarm)%")
                    .font(Deck.display(13).monospacedDigit())
                    .foregroundStyle(Deck.text)
                    .frame(minWidth: 40)
                ChipButton(label: "+", color: Deck.muted) {
                    model.contextAlarm = (model.contextAlarm + 5)
                        .clamped(to: ContextAlarm.clampPercent)
                }
                .help("Raise the alarm threshold")
                Spacer()
                Text("NOTIFY WHEN A SESSION'S CONTEXT FILLS PAST THIS.")
                    .font(Deck.label(11))
                    .kerning(0.4)
                    .foregroundStyle(Deck.dim)
            }
        }
    }

    private var linearSection: some View {
        section("LINEAR — OPTIONAL") {
            underlinedField("WORKSPACE-SLUG", text: $model.linearWorkspace)
                .help("linear.app/<slug> — enables branch-ticket deep links from rows")
        }
    }

    private var footer: some View {
        HStack {
            Button(action: { model.skip() }) {
                Text("SKIP")
                    .font(Deck.display(11))
                    .kerning(1.4)
                    .foregroundStyle(Deck.muted)
            }
            .buttonStyle(.plain)
            .help("Close setup — reopen any time from the popover's SETUP button")
            Spacer()
            if let error = model.saveError {
                Text(error.uppercased())
                    .font(Deck.label(11))
                    .kerning(0.4)
                    .foregroundStyle(Deck.amber)
                    .lineLimit(1)
                Spacer()
            }
            ChipButton(label: "COMPLETE SETUP") { model.completeSetup() }
                .help("Write choices to ~/.config/argus/config.json")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Building blocks

    private func section(_ title: String, chip: StepChip? = nil,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title)
                    .font(Deck.display(11))
                    .kerning(1.7)
                    .foregroundStyle(Deck.dim)
                Spacer()
                chip
            }
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func underlinedField(_ prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField("", text: text,
                      prompt: Text(prompt).font(Deck.label(13)).foregroundStyle(Deck.dim))
                .textFieldStyle(.plain)
                .font(Deck.label(13))
                .kerning(0.3)
                .foregroundStyle(Deck.text)
            Rectangle().fill(Deck.line).frame(height: 1)
        }
    }
}

/// Read-only status lozenge for setup steps. Same metrics as the row
/// Annunciator but deliberately its own vocabulary — annunciator words mean
/// session states, and that list is fixed by the design system.
struct StepChip: View {
    let word: String
    let color: Color

    var body: some View {
        Text(word)
            .font(Deck.display(11))
            .kerning(1.7)
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 3)
                .stroke(color.opacity(0.8), lineWidth: 1))
    }
}

/// Selectable option lozenge (editor/terminal choices).
struct SelectChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Deck.display(11))
                .kerning(1.7)
                .foregroundStyle(selected ? Deck.cyan : Deck.muted)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(selected || hovering ? Deck.cyan.opacity(0.05) : .clear)
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .stroke(selected ? Deck.cyan.opacity(0.8) : Deck.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Bordered caps action button — onboarding's primary affordance.
struct ChipButton: View {
    let label: String
    var color: Color = Deck.cyan
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Deck.display(11))
                .kerning(1.7)
                .foregroundStyle(color)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(hovering ? color.opacity(0.05) : .clear)
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .stroke(color.opacity(0.8), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
