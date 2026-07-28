# macOS Platform

> _Cross-cutting standard — window management, notifications, automation, and signing. Most rules here encode behaviour that only shows up at runtime on a real Mac, never in tests._

## App shape

- **Argus is a `MenuBarExtra(.window)` accessory app.** `LSUIElement` in the bundle's Info.plist keeps it out of the Dock; `AppDelegate` also sets `.accessory` so `swift run` (no bundle) behaves the same. There is no main window — the one exception is the transient onboarding window (`OnboardingWindowController`: AppKit `NSWindow` + `NSHostingView`, presented with `NSApp.activate` while staying `.accessory`, because a SwiftUI `Window` scene is created at launch on macOS 14 — `.defaultLaunchBehavior(.suppressed)` is 15+). New persistent surfaces still belong in the popover or the row context menu, not in new windows.
- **MenuBarExtra window-style popovers have no dismiss API.** Dismiss by mimicking a status-item click (`SessionListView.dismissPopover`: find the `NSStatusBarButton`, `performClick`) so MenuBarExtra's internal presented state stays in sync — closing the popover's window directly desyncs it and the status item then needs two clicks to reopen. `performClick` toggles, so the helper acts only while the popover window is actually visible. SwiftUI `.alert`/`.confirmationDialog` don't reliably present from these panels on macOS 14 — use `NSAlert` with `NSApp.activate` first (exemplar: `RowActions.endSession`).

## Notifications

- **`UNUserNotificationCenter` requires a real `.app` bundle** — it throws under `swift run` *and* `swift test`. Every path into it is gated on `Notifier.hasBundle` (which checks for a `.app` bundle path, not just a bundle id); ungated calls will crash the dev loop. The NSLog fallback is the designed dev-mode behaviour, not a stub.
- **The notification delegate must be installed before launch finishes** to receive cold-launch taps — guaranteed because `ArgusController` (which builds `Notifier`) is created during `App` init. Don't move that construction later. Authorization is requested separately: at launch for users past onboarding, from the onboarding notifications step otherwise — keep every `UNUserNotificationCenter` call behind `hasBundle`.

## AppleScript & automation (terminals)

- **Values interpolated into AppleScript source are untrusted.** Session and iTerm ids come from hook input: validate their shape with `Escape.isUUIDLike` and refuse, rather than trying to escape arbitrary content. Anything else crossing into script source goes through `Escape.appleScriptString` (and `Escape.shellSingleQuoted` first if it lands in a shell command, in that order — shell quote, then AppleScript-escape the whole command). Ghostty's focus handle is the claude pid — an integer, injection-safe by type.
- **The first `osascript` call to a terminal triggers the Automation (TCC) consent prompt**, keyed to the bundle id *per target app* — iTerm2 and Ghostty prompt separately. Ad-hoc re-signing keeps the grants as long as the bundle id is stable; changing `CFBundleIdentifier` re-prompts every user.
- **iTerm2 and Ghostty are the supported backends** (`TerminalFocus` dispatches per session; `steering/EVENT_LOG_AND_HOOKS.md` covers how the hook detects the terminal). Ghostty needs 1.3+ with its preview AppleScript dictionary enabled (`macos-applescript`); ended Ghostty sessions can't be located (no per-session identity survives the claude process), so they always resume — no tab-open badge. There is deliberately no Terminal.app fallback. Degrade gracefully when a terminal is absent or unscriptable (surface the failure via the amber strip, don't crash), and keep the README's requirements honest about it.
- **Never probe a terminal that isn't running** — `tell application` launches it. Gate probes on `TerminalFocus.isRunning` (exemplar: the popover's iTerm tab scan); only resume launches a terminal, deliberately.

## Distribution

- **`scripts/bundle.sh` produces an ad-hoc-signed app** — fine for personal/open-source use; Gatekeeper on other machines will require right-click-Open. There is no notarisation pipeline; do not claim otherwise anywhere user-facing.
- **The bundle's Info.plist is `scripts/Info.plist`** — edit it there, never inside `dist/` (which is disposable build output).
- **The app icon is the committed `scripts/AppIcon.icns`**, generated from `scripts/AppIcon.svg` by `scripts/make-icon.sh` (sips + iconutil, system tools only). Edit the SVG and regenerate — never the .icns by hand; `bundle.sh` copies it into `Contents/Resources` before signing, so a missing .icns fails the bundle loudly.

## Verification

0. **Reproduce bundled-app bug reports against a fresh bundle before reading code.** The running Argus.app (dist/ or /Applications) can be arbitrarily stale — "feature X does nothing" is often behaviour that already works at HEAD but isn't in the binary the user launched. Rebundle, relaunch, then diagnose.
1. `./scripts/bundle.sh && open dist/Argus.app` — menu-bar icon appears, popover opens, no Dock icon; first run also presents the onboarding window.
2. Notification paths: only testable from the bundled app (grant the prompt via onboarding's ENABLE button, or at launch once onboarding is recorded).
3. Focus/resume paths: click a row with its terminal running (iTerm2 and Ghostty each); the first click per terminal must show that terminal's Automation prompt, not a silent failure.
4. Ghostty-only check: quit iTerm2, open the popover — iTerm2 must not launch.
