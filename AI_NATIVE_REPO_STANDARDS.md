# AI-Native Development Standards

The canon for how we build software with coding agents — distilled from what's emerged as best practice across our repos and aligned with [official guidance and the wider agentic-engineering literature](#sources). It covers two things: **how a repo is steered** (the context that shapes how an agent behaves) and **how we work** (the loop a session runs through). It is written to be **portable**: copy it into any repo, adapt the specifics, keep the rules.

> CLAUDE.md is the source of truth. AGENTS.md points to it. The harness enforces what convention can't. Plans and worklogs live in the repo. Every task verifies itself; every agentic feature earns its eval. Every session leaves the context better than it found it.

These standards describe the **agentic-engineering** end of a spectrum that runs from casual *vibe coding* (prompt, accept the output, paste the error back when it breaks) to disciplined agentic engineering (AI implements inside human-designed specs, tests, evals, and guardrails). The line between the two isn't whether you use AI — it's how much structure, verification, and judgment surround the output. Pick your place on that spectrum by the stakes: a throwaway prototype can be pure vibes; anything an organisation depends on cannot. Two principles set the altitude for everything below — **structure scales, vibes don't**, and **AI amplifies the engineering culture it lands in**, multiplying a team's strengths and its weaknesses alike. The rules here are how you make sure it multiplies the right things.

Each rule states the rule and **why it matters** — agents and humans both make better edge-case calls when they know the reason, not just the rule.

---

## What we mean by "steering"

Before the rules, the term they all hang on.

**Steering** is the durable, prescriptive context that shapes how an agent behaves in a repo — the rules it is *steered by* every session, whether or not a human opens the file. It is loaded up front and is always on. In our repos that's `CLAUDE.md` at every altitude plus the standards under `steering/`. In context-engineering terms it is the **static context**: always present, paid for on every turn — as opposed to **dynamic context** (skills, tool results, retrieved docs, windowed history) that loads only when a task calls for it.

We deliberately separate steering from two neighbours:

- **Steering ≠ documentation.** Documentation (`docs/`, READMes) is descriptive and consulted on demand: a human reads it when they need it. Steering is prescriptive and consumed automatically: it enters the agent's context at the start of every session and changes the output even when nobody reads it.
- **Steering ≠ code.** Code is what runs. Steering is the intent, conventions, and invariants behind the code that can't be derived by reading it.

**Why we aligned on the word.** Naming this category matters because it has its own rules that documentation doesn't: steering must be *always true* (a stale rule actively produces wrong code), *concise* (it costs context budget on every single turn), and *broadly applicable* (it loads whether or not it's relevant). "Documentation" smuggles in none of those constraints; "steering" names exactly the thing we have to keep true, short, and load-bearing. The static-vs-dynamic boundary — what earns a place in always-on steering versus what's left to load on demand — is a first-class architectural decision, versioned and reviewed like any other. Once you have the word, the rest of this document is just how to keep steering healthy.

A corollary: **only broadly-applicable rules belong in steering.** Knowledge that's relevant only sometimes (a niche workflow, deep domain reference) belongs in a **skill** the agent loads on demand — not in a `CLAUDE.md` that taxes every conversation.

---

## Calibrating steering to the model generation

Steering is written *for* a model, and the current generation (the Claude 5 family — Opus 5 and the Mythos-class models) changed what good steering looks like. Four calibrations, drawn from the official prompting guides:

- **A brief instruction beats an enumerated behaviour list.** Instruction-following is strong enough that "keep responses concise and lead with the outcome" does the work that used to need ten bullet points of named anti-patterns. Over-prescriptive steering and skills written for older models now *reduce* output quality — when migrating, A/B with the old scaffolding removed before keeping it.
- **Delete instructions the model already follows by default.** "Double-check your answer", "include a final verification step", "use a subagent to verify your work" cause over-verification and wasted tokens — these models self-check without being told. Verification sections in steering should hand the agent *runnable commands and manual checklists*, not re-check rituals.
- **State boundaries and scope, not process.** The highest-value additions are scope discipline ("deliver what was asked; don't quietly narrow, widen, or transform the task"), simplicity guardrails ("no abstractions beyond what the task requires; validate only at system boundaries"), and behavioural boundaries ("when the user describes a problem, the deliverable is your assessment — don't fix until asked"). Give the reason alongside the request: these models use intent, and a rule with its *why* is applied better at the edges.
- **Never instruct an agent to echo or explain its internal reasoning in output.** On Mythos-class models that can trigger a refusal category; everywhere it produces noise. If reasoning visibility matters, it comes from the platform's thinking summaries, not from prompt-engineered self-narration.

Also retire the older-model compensations: aggressive "CRITICAL: YOU MUST" phrasing over-triggers on literal instruction-followers, and dialled-up delegation prompts ("use subagents liberally") invert on models that already delegate readily — current guidance is to *cap* delegation, not encourage it.

---

## Part A — Steering: keeping the repo's context healthy

### 1. `CLAUDE.md` is the single source of truth

**Rule 1 — `CLAUDE.md` is canonical at every altitude.** It holds the real steering content — architecture, conventions, invariants, the map. There is exactly one canonical steering file per directory altitude, and it is `CLAUDE.md`. Generate a starter with `/init` and refine it over time; treat it like code — review it when things go wrong and prune it regularly.

*Why it matters:* Agents read steering fresh every session. One canonical home means one thing to keep true. The moment steering is split across two files of record they drift, and a drifting steering doc is worse than none — agents trust it and produce wrong code from it.

### 2. `AGENTS.md` is a thin pointer

**Rule 2 — `AGENTS.md` redirects to `CLAUDE.md`; it never carries content.** Tools that look for the vendor-neutral `AGENTS.md` get a one-line pointer back to the canonical file:

```md
# AGENTS.md
This repo's canonical steering lives in **CLAUDE.md** — read that.
```

*Why it matters:* As a Claude-Code-first team we want a single file of record, but we still want to interoperate with tools that expect `AGENTS.md`. A pointer satisfies both without maintaining a second, drift-prone copy. The cost — those tools get a pointer, not content — is deliberate and acceptable.

### 3. Steering is hierarchical — one `CLAUDE.md` per package or substantial module

**Rule 3 — Every package and every substantial module carries its own `CLAUDE.md`** stating its purpose, boundary, and local conventions — *substantial* being the operative word: in a small repo the root file plus `steering/` is the whole hierarchy, and per-module files are added only when sessions repeatedly stumble in a module. Hold **altitude discipline**: the root file owns cross-cutting invariants and the map; a module file owns its purpose, boundary, and local rules. Don't duplicate across altitudes — link instead.

*Why it matters:* A single giant root file can't hold a whole monorepo's detail without becoming unreadable, and detail far from the code it governs goes stale unnoticed. But empty ceremony cuts the other way too — a per-module file with nothing local to say is pure maintenance load. Grow steering with the code.

### 4. Compose steering with links, not copy-paste

**Rule 4 — Shared steering has one home; every reference is a link** (or an `@`-import where inlining at load time is genuinely wanted). Never fork a copy of a standard into a second file.

*Why it matters:* One definition per standard is what makes "keep it always true" achievable. Plain markdown links keep steering read-on-demand and the always-on context lean; `@`-imports inline the target into every session and should be reserved for content that truly belongs in static context.

### 5. Keep steering broadly-applicable; push sometimes-knowledge to skills

**Rule 5 — A `CLAUDE.md` is loaded every session, so it carries only what applies broadly.** Bash commands an agent can't guess, code style that differs from defaults, repo etiquette, project-specific architectural decisions, non-obvious gotchas. Domain knowledge and workflows that are only *sometimes* relevant go in a **skill** (`.claude/skills/<name>/SKILL.md`), which the agent loads on demand via progressive disclosure. For each line of steering, apply the prune test: *"Would removing this cause the agent to make a mistake?"* If not, cut it.

*Why it matters:* A bloated `CLAUDE.md` is self-defeating — when it's too long the agent ignores half of it and the load-bearing rules get lost in the noise. Worse, it taxes context budget on every turn for knowledge that's relevant on few of them. Skills give that knowledge a home that costs nothing until it's needed.

### 6. Keep every `CLAUDE.md` under 200 lines

**Rule 6 — A `CLAUDE.md` is a map, not a manual: cap it at ~200 lines.** When one grows past that, the detail belongs in a `steering/` standard, a skill, or a deeper nested `CLAUDE.md`, linked from it.

*Why it matters:* The cap is the enforceable backstop to Rule 5. A bloated steering doc stops being read — by humans and agents alike — and forces the detail down to the altitude that owns it, which is also where it's most likely to stay correct.

### 7. `steering/` holds standards; `docs/` holds reference — at every altitude

**Rule 7 — Split prescriptive rules from descriptive reference.** `steering/` = "always do X" standards (coding conventions, error handling, security, a11y, testing). `docs/` = reference and rationale (architecture decision logs, product briefs, setup guides). This split applies at the root *and* inside each surface/package.

*Why it matters:* Rules and reference have different lifecycles and readers (see "What we mean by steering"). Mixing them means an agent hunting for the testing rule wades through a product brief. Keeping standards in one predictable place is what lets "start there, don't reinvent conventions from the code" actually work.

### 8. Don't duplicate facts that live in code

**Rule 8 — Steering documents what code can't tell you; it never paraphrases what code already says.** Do document architecture, conventions, invariants, cross-module data flow, auth boundaries, and the *why* behind non-obvious choices. Don't restate version numbers, table/column lists, hex/pixel values, function signatures, export lists, or model IDs — link to their authoritative home in code instead.

*Why it matters:* Any fact copied out of code drifts the instant someone changes the source, and the stale copy in a trusted steering doc is exactly the kind of confident-but-wrong input that derails an agent.

### 9. Never state aspirational architecture as current fact

**Rule 9 — If an invariant isn't yet enforced by the type system or CI, say so.** Mark it as a target with its adoption status, or soften the claim. Don't assert that a not-yet-wired guarantee holds.

*Why it matters:* Agents trust steering literally. An overclaim ("auth is centralised and cannot be bypassed") becomes a trap that produces code relying on a guarantee that doesn't exist yet. An honest "this is the target; here's what's wired today" lets the agent build toward it correctly.

### 10. Describe current behaviour, not the doc's own history

**Rule 10 — Edit steering as if authoring it today.** Remove text that only parses if you remember a previous version ("previously we did X; now…"). The one exception: a historical anchor earns its place when it explains *why a current constraint exists* and a reader needs that to judge edge cases ("we chose SQLite over Postgres because X" — keep; "we used to use Postgres" — cut).

*Why it matters:* Every steering file is read fresh by a model with no memory of how it evolved. History-narrating text is dead weight at best and contradictory instruction at worst.

---

## Part B — The harness: enforce what convention can't, equip what agents need

An agent is the model *plus* the harness around it — the rules, tools, hooks, permissions, and observability that let it actually finish work. The model is one input; the harness is the team's surface area, and it's where reliability is won or lost. So when an agent misbehaves, **suspect the harness before the model**: most agent failures are configuration failures — a missing tool, a vague rule, an absent guardrail, or a context window stuffed with noise — not a model that's too weak.

### 11. Install and keep the shared harness

**Rule 11 — Confirm the team harness is installed and current before working:** the Claude Code CLI, the team plugin/marketplace (skills, subagents, slash commands), and any MCP servers the repo expects. If a repo depends on a skill or agent you don't have, fix that setup gap first — don't work around it by hand. Treat the harness — shared prompts, skills, MCP connections, eval suites — as versioned infrastructure owned by named engineers, built once and refined many times, not as personal config.

*Why it matters:* AI-native work assumes a shared baseline of capability. A teammate running without the harness produces inconsistent results, re-implements what the harness already does, and can't reproduce another teammate's workflow. The harness is the floor, not a bonus — and it compounds in value only if it's maintained like code rather than left to drift per-machine.

### 12. Back invariants with CI or types, not convention

**Rule 12 — If an invariant must hold, make it impossible to violate silently.** Encode it in the type system or a CI gate rather than a sentence in a doc — a conformance script that fails the build on a forbidden dependency pattern, domain boundaries encoded in types so a violation is a compile error.

*Why it matters:* Under AI-native delivery — many deploys a day, agents writing most of the code — nobody reliably remembers to enforce a convention. A rule that isn't mechanically checked will be broken, and the break won't be noticed until it's in production.

### 13. Use hooks for what must happen every time

**Rule 13 — When an action must happen with zero exceptions, make it a hook, not a `CLAUDE.md` line.** Steering is advisory — the agent may or may not follow it; hooks are deterministic and guaranteed. Wire the cheap, fast gates (type-check, lint) on pre-commit, and use edit/stop hooks for checks that must run on every change. Keep hooks honest: use the repo's real package manager and put the hook where git actually invokes it (repo root, not a sub-package).

*Why it matters:* The cheapest place to catch a type or lint error is before it's committed, and "the agent usually remembers to run lint" is not a guarantee. A dead or wrong hook is worse than none — it gives false confidence while letting breakage through.

### 14. Commit a permission allowlist; install the CLI tools

**Rule 14 — Check in a repo-level `.claude/settings.json` allowlist** for the routine, safe commands a session runs constantly (build, lint, type-check, test, read-only git and search), and keep personal/experimental permissions in a gitignored `settings.local.json`. Install the CLI tools the repo leans on (`gh`, cloud CLIs) so agents interact with external services context-efficiently rather than via raw, rate-limited API calls.

*Why it matters:* Without a committed allowlist every teammate gets permission-prompted on routine commands — friction that trains people to approve blindly. A shared allowlist makes the safe path frictionless and the unusual command conspicuous.

### 15. Make agent behaviour observable

**Rule 15 — Instrument the loop so you can tell whether an agent is doing well or quietly drifting.** Keep the evidence a run produces — the commands and their output, test and eval results, what a verification subagent found. For agentic *features* you ship, capture traces of each run plus cost, latency, and eval scores over time. Reviewable evidence beats asserted success.

*Why it matters:* Without observability there's no way to distinguish a run that succeeded from one that merely looked like it did, and no way to catch slow regressions — quality drift, climbing token cost, a tool silently failing. You can't improve, or trust, a loop you can't see.

### 16. Match the model to the task; treat tokens as a budget

**Rule 16 — Spend capability where it pays.** Route hard, ambiguous, high-stakes work (architecture, gnarly implementation, adversarial review) to the most capable model and effort tier; route deterministic, low-complexity work (mechanical edits, test scaffolding, routine checks) to smaller, faster, cheaper ones — and remember that on current models the *lower effort tiers* of a capable model often beat a lesser model outright. Feed the model a dense, high-signal context rather than dumping whole files in.

*Why it matters:* AI-native delivery's ongoing cost is the token economy. Paying frontier prices to fix a typo, or stuffing a 100k-token repo into every prompt, burns budget for no quality gain — while under-powering a genuinely hard task burns more in retry loops than the bigger model would have cost.

---

## Part C — The working loop: how a session runs

### 17. Explore, then plan, then code — and write the plan into the repo

**Rule 17 — Separate research and planning from implementation.** For anything beyond a one-sentence diff: explore the relevant code first (plan mode), produce a plan, then implement against it. Commit substantial plans to the repo under `plans/<YYYY-MM-DD>-<slug>/plan.md` (or keep `plans/` local-only in solo repos — decide once, in `.gitignore`), carrying their context (why, scope in/out, decisions taken with the user), the work items, and a status you keep current. Skip the ceremony for genuinely small, clear changes.

*Why it matters:* Letting an agent jump straight to code produces confident solutions to the wrong problem. A plan in the repo is durable shared context: it survives the session, it's reviewable, and it tells the next person — or agent — what was intended and why.

### 18. Worklogs live alongside the plan

**Rule 18 — Keep a `worklog.md` next to the plan** recording what actually happened — timestamped actions, deviations, and a close-out stamp. The plan is intent; the worklog is the record.

*Why it matters:* Plans drift from reality as work uncovers surprises. The worklog captures the delta — what changed, what was added mid-flight, what was deferred — so a future session can trust the plan's *intent* while knowing the *actual* path taken.

### 19. Give every task a verification the agent can run

**Rule 19 — Hand the agent a check that returns pass/fail** — a test, a build, a linter, a script that diffs output against a fixture, a screenshot compared to a design — and have it iterate until the check passes. Prefer showing evidence (the command run and its output) over asserting success. For unattended runs, gate the stop harder: a `/goal` condition, a Stop hook, or a verification subagent. This pins down the **deterministic** part of correctness; Rule 20 covers the rest. Note what this rule is *not*: it does not mean instructing the agent to "double-check" or "re-verify" — current models self-check by default, and mandated re-check rituals only add cost (see *Calibrating steering to the model generation*). Provide the check; don't script the checking behaviour.

*Why it matters:* An agent stops when the work *looks* done. Without a check it can run, "looks done" is the only signal, and you become the verification loop. A runnable check closes the loop on its own and is the single biggest difference between a session you have to watch and one you can walk away from. If you can't verify it, don't ship it.

### 20. Verify non-deterministic behaviour with evals, not just tests

**Rule 20 — Where behaviour isn't deterministic, add evals alongside tests.** Tests check that a function given an input returns the expected output. Evals check what a pass/fail assertion can't pin down — did the agent take a sensible trajectory, choose the right tools, and produce output that meets a quality bar — scored against a labelled dataset, a rubric, or an LM judge. For any AI *feature* we ship, an eval suite with an explicit rubric is the bar to clear, not a working demo.

*Why it matters:* A demo proves a feature can succeed once; an eval proves it succeeds reliably. For non-deterministic systems "the tests pass" is necessary but not sufficient — without evals you're still vibe coding, however disciplined the prompts.

### 21. Manage context aggressively

**Rule 21 — Treat the context window as the scarce resource it is.** `/clear` between unrelated tasks. Scope investigations narrowly, and delegate wide research to **subagents** so the file-reading happens in their context, not your main one. If you've corrected the agent more than twice on the same issue, the context is polluted with failed approaches — `/clear` and restart with a sharper prompt that folds in what you learned. Delegation is for genuinely independent, sizeable tracks of work — current models delegate readily on their own, so steering should bound it (spawn counts, when *not* to delegate), not exhort it.

*Why it matters:* Performance degrades as context fills — the agent starts forgetting earlier instructions and making more mistakes. A clean session with a better prompt almost always beats a long one carrying accumulated corrections and irrelevant file dumps.

### 22. Have an independent reviewer check substantial work before "done"

**Rule 22 — Before counting substantial work as done, have a fresh context review the diff** against the plan and the requirements. A reviewer subagent sees only the diff and the criteria, not the reasoning that produced the change, so it judges the result on its own terms — fresh-context review consistently outperforms self-critique. Brief it on the failure shape AI actually produces: not syntax errors but *conceptual* ones — wrong business-logic assumptions, unhandled edge cases, hallucinated dependencies. Scope the review to gaps that affect correctness or stated requirements — not style preferences — and tell it to report everything it finds, filtering severity downstream (severity filters in the prompt depress recall on literal instruction-followers). Calibrate to the stakes: this is for substantial changes, not a ritual appended to every small edit.

*Why it matters:* The agent that wrote the code is biased toward it, and AI's mistakes have shifted from syntax to plausible-looking code that's subtly wrong. A fresh reviewer briefed on that failure shape catches what the author and the type-checker miss. (Temper it: a reviewer told to find gaps will always find some — gate on correctness and requirements.)

### 23. Run the self-learning loop — leave the context better than you found it

**Rule 23 — Close substantial sessions by feeding what you learned back into the harness.** When a session surfaces a correction, a non-obvious pattern, or a mistake worth never repeating, propagate it: update the right `CLAUDE.md` or `steering/` doc, refresh architecture docs for the modules you changed, and record durable cross-session facts in memory — one lesson per note, with the why; update existing notes rather than duplicating; delete notes that turn out to be wrong.

*Why it matters:* This is the compounding mechanism of AI-native development. Every session either improves the context future sessions inherit or lets it rot. A repo whose steering gets a little truer after each piece of work gets *easier* to work in over time; one that doesn't decays into the same mistakes on repeat.

---

## Part D — Failure patterns to recognise early

Naming these makes them easier to catch in the moment:

- **The kitchen-sink session.** One task, then an unrelated one, then back — context full of irrelevance. → `/clear` between unrelated tasks.
- **Correcting in circles.** Two-plus corrections on the same issue, still wrong. → `/clear` and write a better initial prompt.
- **The over-specified `CLAUDE.md`.** Too long, so the agent ignores half of it. → Prune ruthlessly; convert must-happen rules to hooks.
- **The over-prescriptive skill.** Step-by-step scaffolding written for an older model that now degrades output. → State the goal and constraints; A/B with the scaffolding removed.
- **The mandated re-check.** "Double-check / verify with a subagent" instructions layered on a model that already self-verifies. → Delete them; keep the runnable check (Rule 19).
- **The trust-then-verify gap.** A plausible implementation that doesn't handle the edge cases. → Always provide a runnable check (Rule 19).
- **The passing-demo trap.** An AI feature works once in a demo, so it ships. → A demo isn't an eval; gate on a rubric-scored eval suite (Rule 20).
- **Blaming the model.** An agent misbehaves and the instinct is to swap models. → Usually it's a harness gap. Fix the configuration first (Part B).
- **The infinite exploration.** An unscoped "investigate X" that reads hundreds of files. → Scope it, or delegate to a subagent.
- **The overclaiming steering doc.** A `CLAUDE.md` asserting a guarantee that isn't wired yet. → Mark targets as targets (Rule 9).

---

## The loop, in one line

Install the harness → read the steering → explore, plan into the repo → build against enforced invariants → verify with tests and evals → review substantial work in a fresh context → observe the run → log what happened → feed the learnings back. Then the next session — yours or an agent's — starts from a better place than you did.

---

## Sources

Grounded in official guidance and the agentic-engineering literature, adapted into team standards:

- [Best practices for Claude Code](https://code.claude.com/docs/en/best-practices)
- [CLAUDE.md / memory](https://code.claude.com/docs/en/memory)
- [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- [Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)
- [Prompting Claude Opus 5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5) and [Prompting Claude Fable 5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5) — the Class 5 calibrations above
- *The New SDLC With Vibe Coding* — Osmani, Saboo & Kartakis (Google, May 2026)
