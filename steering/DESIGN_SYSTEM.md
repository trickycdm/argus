# Design System — "Flight Deck"

> _Cross-cutting standard for all UI. The theme is a glass cockpit at night: a dark instrument panel read at a glance, not a document read at leisure. Every visual choice serves the two-second check: who needs me?_

## Tokens

All colors and fonts come from `Deck` (`Sources/Argus/Views/Theme.swift`) — that file is the authority; this table names roles, not values.

| Token | Role |
|---|---|
| `Deck.bg` / `line` / `rowLine` | Panel and hairlines |
| `Deck.text` / `muted` / `dim` | Three-step text hierarchy |
| `Deck.cyan` | Normal operations (working, links, toggles) |
| `Deck.amber` | **"Act now" only** — blocked sessions, context alarm, failures |
| `Deck.green` | Work ready for review |
| `Deck.stall` / `red` | Degraded / lost |
| `Deck.display(_:)` / `label(_:)` | Condensed caps identity / body labels |

## Rules

- **New UI color = token, never a literal.** If a state needs a color that doesn't exist, add a token to `Deck` with a role comment. Hex values appear in exactly one file.
- **Amber is reserved (avionics color law).** It means the user must act. Don't use it for decoration, emphasis, or non-actionable info — diluting amber breaks the glanceability the whole app exists for.
- **The annunciator vocabulary is fixed:** HOLD / REVIEW / RUN / STALL / STBY / LOST / END. New states need a new short caps word and a `SessionStatus` case, not a repurposed one.
- **Digits are always `monospacedDigit()`** — instrument readouts must not jitter as values tick.
- **Two animations exist (HOLD flash, RUN breathe) and that's the budget.** Movement means "state demands attention"; ambient motion would train the eye to ignore it.
- **The UI is deliberately dark-only** (`.environment(\.colorScheme, .dark)` on the popover) — the panel *is* the brand. A light theme is a product decision, not a drive-by patch.
- **Strips and hints follow the established grammar:** full-width row between hairline dividers, caps label, kerning, an SF Symbol at ~9pt (exemplars: untracked-processes hint, transient alert strip).
- **A nested row is subordinate in three ways at once:** an `└─` elbow, a deeper leading inset, and a smaller/`Deck.muted` title. Indent alone doesn't read as attachment at a glance, and a nested row that keeps full title weight competes with its owner. Its annunciator, gauge, and readouts stay full-size — the nesting says *whose* work it is, never that the work matters less.

## Decisions

- Condensed caps + kerning gives rows an instrument-placard look and fits more in 400pt; `AvenirNextCondensed` ships with macOS, so there are no bundled font assets. If it's ever unavailable, `.custom` falls back to the system font — acceptable degradation.
- The context gauge reads like an N1 gauge: filled arc + centered percent, amber at the alarm threshold. It is the row's leading element because context exhaustion is the most common "act soon" state.

## Verification

1. `grep -rn "Color(hex:" Sources/Argus/Views | grep -v Theme.swift` stays empty.
2. `swift run` — check the popover at a glance from arm's length: blocked rows should be the only amber on screen.
