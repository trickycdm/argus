# macOS Platform

> _Cross-cutting standard — window management, notifications, automation, and signing. Most rules here encode behaviour that only shows up at runtime on a real Mac, never in tests._

## App shape

- **Argus is a `MenuBarExtra(.window)` accessory app.** `LSUIElement` in the bundle's Info.plist keeps it out of the Dock; `AppDelegate` also sets `.accessory` so `swift run` (no bundle) behaves the same. There is no main window — do not add one; new surfaces belong in the popover or the row context menu.
- **MenuBarExtra window-style popovers have no dismiss API.** Closing the key window (`SessionListView.dismissPopover`) is the accepted approach. SwiftUI `.alert`/`.confirmationDialog` don't reliably present from these panels on macOS 14 — use `NSAlert` with `NSApp.activate` first (exemplar: `RowActions.endSession`).

## Notifications

- **`UNUserNotificationCenter` requires a real `.app` bundle** — it throws under `swift run` *and* `swift test`. Every path into it is gated on `Notifier.hasBundle` (which checks for a `.app` bundle path, not just a bundle id); ungated calls will crash the dev loop. The NSLog fallback is the designed dev-mode behaviour, not a stub.
- **The notification delegate must be installed before launch finishes** to receive cold-launch taps — guaranteed because `ArgusController` (which builds `Notifier`) is created during `App` init. Don't move that construction later.

## AppleScript & automation (iTerm2)

- **Values interpolated into AppleScript source are untrusted.** Session and iTerm ids come from hook input: validate their shape with `Escape.isUUIDLike` and refuse, rather than trying to escape arbitrary content. Anything else crossing into script source goes through `Escape.appleScriptString` (and `Escape.shellSingleQuoted` first if it lands in a shell command, in that order — shell quote, then AppleScript-escape the whole command).
- **The first `osascript` call to iTerm2 triggers the Automation (TCC) consent prompt**, keyed to the bundle id. Ad-hoc re-signing keeps the grant as long as the bundle id is stable; changing `CFBundleIdentifier` re-prompts every user.
- **iTerm2 is a hard dependency for focus/resume** — there is deliberately no Terminal.app fallback. Degrade gracefully when it's absent (surface the failure, don't crash), and keep the README's requirements honest about it.

## Distribution

- **`scripts/bundle.sh` produces an ad-hoc-signed app** — fine for personal/open-source use; Gatekeeper on other machines will require right-click-Open. There is no notarisation pipeline; do not claim otherwise anywhere user-facing.
- **The bundle's Info.plist is `scripts/Info.plist`** — edit it there, never inside `dist/` (which is disposable build output).

## Verification

1. `./scripts/bundle.sh && open dist/Argus.app` — menu-bar icon appears, popover opens, no Dock icon.
2. Notification paths: only testable from the bundled app (grant the permission prompt on first launch).
3. Focus/resume paths: click a row with iTerm2 running; first run must show the Automation prompt, not a silent failure.
