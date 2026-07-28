import SwiftUI

struct SessionRowView: View {
    var session: Session
    var actions: RowActions
    var onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 14) {
                ContextGauge(fraction: session.contextFraction)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(session.projectName.uppercased())
                            .font(Deck.display(16))
                            .kerning(0.8)
                            .foregroundStyle(Deck.text)
                            .lineLimit(1)
                        if let branch = session.gitBranch {
                            Text(branch)
                                .font(Deck.label(12))
                                .kerning(0.4)
                                .foregroundStyle(Deck.dim)
                                .lineLimit(1)
                        }
                        if let git = session.gitState {
                            GitChip(state: git)
                        }
                        if actions.isSnoozed(session) {
                            Image(systemName: "bell.slash")
                                .font(.system(size: 9))
                                .foregroundStyle(Deck.dim)
                                .help("Notifications snoozed")
                        }
                    }
                    Text(session.lastAssistantLine ?? statusDescription)
                        .font(Deck.label(13))
                        .kerning(0.3)
                        .foregroundStyle(Deck.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Annunciator(status: session.status)
                    // TimelineView pauses off-screen, so the once-per-second
                    // label update costs nothing while the popover is closed.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Format.elapsed(since: session.statusSince, now: context.date))
                            .font(Deck.label(12).monospacedDigit())
                            .foregroundStyle(timeColor)
                    }
                    if session.tokens.total > 0 || session.model != nil {
                        Text(tokenSummary)
                            .font(Deck.label(11).monospacedDigit())
                            .foregroundStyle(Deck.dim)
                            .help(session.model ?? "")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .background(hovering ? Deck.cyan.opacity(0.05) : .clear)
        }
        .buttonStyle(.plain)
        // Hover actions live in an overlay, not nested in the Button's label:
        // nested plain buttons intermittently fire the row action on macOS 14.
        .overlay(alignment: .trailing) {
            if hovering {
                HoverActionStrip(session: session, actions: actions)
                    .padding(.trailing, 14)
            }
        }
        .contextMenu {
            RowActionsMenu(session: session, actions: actions, focus: onTap)
        }
        .onHover { hovering = $0 }
        .help("Click to focus this session's iTerm tab · right-click for actions")
    }

    private var timeColor: Color {
        switch session.status {
        case .needsYou: return Deck.amber
        case .ready: return Deck.green
        default: return Deck.muted
        }
    }

    private var statusDescription: String {
        switch session.status {
        case .working: return "Working…"
        case .needsYou: return "Blocked — waiting for your input"
        case .ready: return "Finished — ready for review"
        case .stalled: return "No activity for a while"
        case .idle: return "At the prompt"
        case .dead: return "Process gone without exiting cleanly"
        case .ended: return "Session ended"
        }
    }

    private var tokenSummary: String {
        var parts: [String] = []
        if let model = session.model {
            parts.append(Format.modelName(model))
        }
        if session.tokens.total > 0 {
            parts.append(Format.tokens(session.tokens.total))
        }
        if let cost = session.costUSD, cost >= 0.01 {
            parts.append("$\(String(format: "%.2f", cost))")
        }
        return parts.joined(separator: " · ")
    }
}
