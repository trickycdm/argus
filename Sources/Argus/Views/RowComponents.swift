import SwiftUI

// MARK: - Annunciator

/// Avionics-style state chip: short caps word in a thin bordered lozenge.
/// HOLD flashes (blocked = act); RUN breathes (turn in progress); the rest
/// hold steady. The only two animations in the app.
struct Annunciator: View {
    var status: SessionStatus
    @State private var phase = false

    var body: some View {
        Text(word)
            .font(Deck.display(11))
            .kerning(1.7)
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(status == .needsYou && phase ? color.opacity(0.16) : .clear)
            .overlay(RoundedRectangle(cornerRadius: 3)
                .stroke(color.opacity(borderOpacity), lineWidth: 1))
            .opacity(status == .working && phase ? 0.55 : 1)
            .animation(animation, value: phase)
            .onAppear { phase = true }
    }

    private var word: String {
        switch status {
        case .needsYou: return "HOLD"
        case .ready: return "REVIEW"
        case .working: return "RUN"
        case .stalled: return "STALL"
        case .idle: return "STBY"
        case .dead: return "LOST"
        case .ended: return "END"
        }
    }

    private var color: Color { Color(status: status) }
    private var borderOpacity: Double { status == .idle || status == .ended ? 0.45 : 0.8 }

    private var animation: Animation? {
        switch status {
        case .needsYou: return .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
        case .working: return .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
        default: return .default
        }
    }
}

// MARK: - Context gauge

/// Per-session context-window ring, read like an N1 gauge: cyan in normal
/// range, amber at/after the configured alarm. Hollow with "—" before usage
/// data.
struct ContextGauge: View {
    var fraction: Double?

    var body: some View {
        ZStack {
            Circle().stroke(Deck.line, lineWidth: 5)
            if let fraction {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(color(fraction),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(fraction * 100))")
                    .font(Deck.display(13).monospacedDigit())
                    .foregroundStyle(color(fraction))
            } else {
                Text("—")
                    .font(Deck.label(13))
                    .foregroundStyle(Deck.dim)
            }
        }
        .frame(width: 46, height: 46)
        .help(fraction.map {
            "Context window \(Int($0 * 100))% full — alarm at \(Int(Session.contextAlarmAt * 100))%"
        } ?? "No context data yet")
    }

    private func color(_ fraction: Double) -> Color {
        fraction >= Session.contextAlarmAt ? Deck.amber : Deck.cyan
    }
}

// MARK: - Git chip

/// Working-tree summary next to the branch: dirty count, ahead/behind.
/// Segments disappear rather than showing zeros — a clean tree shows nothing.
struct GitChip: View {
    var state: GitState

    var body: some View {
        HStack(spacing: 5) {
            if state.dirty > 0 {
                Text("●\(state.dirty)")
            }
            if let ahead = state.ahead, ahead > 0 {
                Text("↑\(ahead)")
            }
            if let behind = state.behind, behind > 0 {
                Text("↓\(behind)")
            }
        }
        .font(Deck.label(11).monospacedDigit())
        .foregroundStyle(Deck.dim)
        .help(gitHelp)
    }

    private var gitHelp: String {
        var parts: [String] = []
        if state.dirty > 0 { parts.append("\(state.dirty) changed file\(state.dirty == 1 ? "" : "s")") }
        if let a = state.ahead, a > 0 { parts.append("\(a) ahead") }
        if let b = state.behind, b > 0 { parts.append("\(b) behind") }
        return parts.isEmpty ? "Working tree clean" : parts.joined(separator: " · ")
    }
}

// MARK: - Hover actions

/// The three highest-value actions, revealed on hover over the trailing edge.
/// Opaque background keeps them legible over the time/token column.
struct HoverActionStrip: View {
    var session: Session
    var actions: RowActions

    var body: some View {
        HStack(spacing: 4) {
            icon("chevron.left.forwardslash.chevron.right", help: "Open in editor") {
                actions.openEditor(session)
            }
            icon("arrow.triangle.branch", help: "Open on GitHub") {
                actions.openGitHub(session)
            }
            icon(actions.isSnoozed(session) ? "bell.slash.fill" : "bell.slash",
                 help: actions.isSnoozed(session) ? "Unsnooze" : "Snooze notifications 1h") {
                actions.toggleSnooze(session)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Deck.bg.opacity(0.94), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Deck.line, lineWidth: 1))
    }

    private func icon(_ name: String, help: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 11))
                .foregroundStyle(Deck.muted)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
