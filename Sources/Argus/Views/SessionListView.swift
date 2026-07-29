import SwiftUI

struct SessionListView: View {
    var store: SessionStore
    var actions: RowActions
    var focus: (Session) -> Void
    var focusOrResume: (Session) -> Void
    var onAppearRefresh: () -> Void
    var onOpenSetup: () -> Void

    @AppStorage(Prefs.notifyOnStop) private var notifyOnStop = false
    @State private var historyExpanded = false
    @State private var listContentHeight: CGFloat = 0

    /// Grow with content up to ~7 rows, then scroll.
    private static let listMaxHeight: CGFloat = 520

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider

            if store.live.isEmpty {
                Text("NO CONTACTS")
                    .font(Deck.display(13))
                    .kerning(2.2)
                    .foregroundStyle(Deck.dim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                // A ScrollView's ideal height is ~0, so a bare maxHeight
                // collapses the MenuBarExtra window and everything scrolls.
                // Measure the content and size the viewport to fit it, up to
                // the cap — the window grows with entries, then scrolls.
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.live) { session in
                            SessionRowView(session: session, actions: actions,
                                           nestedUnder: store.owner(of: session)) {
                                focus(session)
                                Self.dismissPopover()
                            }
                            if session.id != store.live.last?.id {
                                divider.padding(.horizontal, 16)
                            }
                        }
                    }
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ListHeightKey.self,
                                               value: geo.size.height)
                    })
                }
                .onPreferenceChange(ListHeightKey.self) { listContentHeight = $0 }
                .frame(height: min(max(listContentHeight, 1), Self.listMaxHeight))
            }

            if let alert = store.transientAlert {
                divider
                Label {
                    Text(alert.uppercased())
                        .font(Deck.label(11))
                        .kerning(1)
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9))
                }
                .foregroundStyle(Deck.amber)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
            }

            if store.untrackedRunning > 0 {
                divider
                Label {
                    Text("\(store.untrackedRunning) RUNNING · NOT TRACKED — RESTART TO MONITOR")
                        .font(Deck.label(11))
                        .kerning(1)
                } icon: {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 9))
                }
                .foregroundStyle(Deck.amber.opacity(0.85))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
            }

            if !store.history.isEmpty {
                divider
                DisclosureGroup(isExpanded: $historyExpanded) {
                    ForEach(store.history) { session in
                        HistoryRowView(
                            session: session,
                            tabStillOpen: store.tabStillOpen(session)
                        ) {
                            focusOrResume(session)
                            Self.dismissPopover()
                        }
                    }
                } label: {
                    Text("EARLIER TODAY (\(store.history.count))")
                        .font(Deck.display(11))
                        .kerning(1.7)
                        .foregroundStyle(Deck.dim)
                }
                .tint(Deck.dim)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
            }

            divider
            footer
        }
        .frame(width: 400)
        .background(Deck.bg)
        .environment(\.colorScheme, .dark)
        .onAppear { onAppearRefresh() }
    }

    private var divider: some View {
        Rectangle().fill(Deck.rowLine).frame(height: 1)
    }
}

private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension SessionListView {

    /// MenuBarExtra window-style popovers have no dismiss API, and closing
    /// the popover's NSWindow directly desyncs MenuBarExtra's internal
    /// presented state — the next status-item click toggles the already-
    /// closed popover "off", so reopening takes two clicks. Instead, mimic
    /// the user clicking the status item: MenuBarExtra closes the popover
    /// through its own path and its state stays in sync.
    static func dismissPopover() {
        // performClick toggles — act only while the popover is actually on
        // screen, so a dismiss racing a natural close (another app
        // activating) can't reopen it.
        guard let popover = NSApp.windows.first(where: {
            $0.className.contains("MenuBarExtraWindow")
        }) else {
            NSLog("Argus: MenuBarExtra popover window not found — dismiss skipped")
            return
        }
        guard popover.isVisible else { return }

        guard let button = statusItemButton(), button.state != .off else {
            // Non-toggling fallback: dismisses, at worst with the stale-
            // toggle quirk this path exists to avoid.
            NSLog("Argus: status-item button not found — closing popover directly")
            popover.close()
            return
        }
        button.performClick(button)
    }

    /// The MenuBarExtra's status-item button, reached via its status-bar
    /// window. Multi-display setups add replicant status windows; prefer a
    /// button wired to a target (the one driving the MenuBarExtra).
    private static func statusItemButton() -> NSStatusBarButton? {
        let buttons = NSApp.windows
            .filter { $0.className.contains("NSStatusBarWindow") }
            .compactMap { $0.contentView.flatMap(statusBarButton(in:)) }
        return buttons.first { $0.target != nil } ?? buttons.first
    }

    private static func statusBarButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let found = statusBarButton(in: subview) { return found }
        }
        return nil
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("ARGUS")
                .font(Deck.display(15))
                .kerning(3.2)
                .foregroundStyle(Deck.text)
            Spacer()
            Group {
                if store.needsYouCount > 0 {
                    Text("\(store.needsYouCount) HOLDING")
                        .foregroundStyle(Deck.amber)
                } else if store.readyCount > 0 {
                    Text("\(store.readyCount) TO REVIEW")
                        .foregroundStyle(Deck.green)
                } else {
                    Text("\(store.live.count) TRACKED")
                        .foregroundStyle(Deck.muted)
                }
            }
            .font(Deck.display(11.5).monospacedDigit())
            .kerning(1.7)
            Button(action: { actions.openConfig() }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(Deck.dim)
            }
            .buttonStyle(.plain)
            .padding(.leading, 10)
            .help("Edit Argus config (editor, Linear workspace, boards, context alarm)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var footer: some View {
        HStack {
            Toggle(isOn: $notifyOnStop) {
                Text("NOTIFY ON TURN END")
                    .font(Deck.label(11))
                    .kerning(1.2)
                    .foregroundStyle(Deck.muted)
            }
            .toggleStyle(.checkbox)
            .tint(Deck.cyan)
            Spacer()
            Text("CTX ALARM \(Int(Session.contextAlarmAt * 100))%")
                .font(Deck.label(11).monospacedDigit())
                .kerning(1.2)
                .foregroundStyle(Deck.dim)
            Button(action: {
                Self.dismissPopover()
                onOpenSetup()
            }) {
                Text("SETUP")
                    .font(Deck.display(11))
                    .kerning(1.4)
                    .foregroundStyle(Deck.muted)
            }
            .buttonStyle(.plain)
            .help("Reopen setup (editor, terminal, hooks, notifications)")
            Button(action: { NSApp.terminate(nil) }) {
                Text("QUIT")
                    .font(Deck.display(11))
                    .kerning(1.4)
                    .foregroundStyle(Deck.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct HistoryRowView: View {
    var session: Session
    var tabStillOpen: Bool
    var onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(status: session.status))
                    .frame(width: 5, height: 5)
                Text(session.projectName.uppercased())
                    .font(Deck.label(12.5))
                    .kerning(0.8)
                    .foregroundStyle(Deck.muted)
                if tabStillOpen {
                    Image(systemName: "macwindow")
                        .font(.system(size: 8))
                        .foregroundStyle(Deck.dim)
                        .help("Terminal tab still open — click to focus")
                }
                Spacer()
                if hovering && !tabStillOpen {
                    Text("RESUME")
                        .font(Deck.display(10))
                        .kerning(1.2)
                        .foregroundStyle(Deck.cyan)
                }
                if session.tokens.total > 0 {
                    Text(Format.tokens(session.tokens.total))
                        .font(Deck.label(10.5).monospacedDigit())
                        .foregroundStyle(Deck.dim)
                }
                if let ended = session.endedAt {
                    Text(ended, style: .time)
                        .font(Deck.label(10.5).monospacedDigit())
                        .foregroundStyle(Deck.dim)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tabStillOpen
              ? "Click to focus this session's terminal tab"
              : "Click to reopen this session (claude --resume) in a new terminal tab")
    }
}
