# Architecture & Design Glossary

Canonical vocabulary for designing deep modules and evaluating architecture in DealScout.

## Terms

**Module**:
Anything with an interface and an implementation, scale-agnostic from a single function to a context or subsystem.
_Avoid_: Component, unit, service

**Interface**:
Everything a caller must know to use the module correctly: functions, arguments, invariants, ordering constraints, error modes, and runtime performance.
_Avoid_: API, signature

**Implementation**:
The internal code body of a module that callers never interact with directly.
_Avoid_: Conflating internal implementation with adapter roles

**Depth**:
Leverage at the interface: the amount of behavior a caller or test can exercise per unit of interface complexity they must learn.
_Avoid_: Line-of-code ratios

**Leverage**:
What callers gain from depth: maximum capability with minimal cognitive surface to learn and maintain.
_Avoid_: Indirection, ceremony

**The Deletion Test**:
A heuristic to detect shallow modules: if deleting the module scatters complexity across callers, it was earning its keep; if complexity vanishes, it was pass-through waste.
_Avoid_: Measuring churn by lines deleted

**Seam**:
A place where you can alter behavior without editing in that place (Michael Feathers); the exact location where a module's interface lives.
_Avoid_: Boundary (overloaded with DDD bounded contexts)

**Adapter**:
A concrete implementation that sits at a seam and satisfies an interface. Describes a role, not internal code size.
_Avoid_: Confusing an adapter role with general implementation body

**The Two-Adapter Rule**:
One adapter means a hypothetical seam (indirection without benefit); at least two distinct adapters (e.g. production HTTP + in-memory test double) are required to justify a seam.
_Avoid_: Speculative abstraction / single-adapter ports

**Dependency Categories**:
A classification system for module dependencies:
- *In-process*: Pure computation or memory state; merged directly without seams.
- *Local-substitutable*: Stateful components with local test stand-ins; internal seam only.
- *Remote but owned*: Internal services across network boundaries; port with HTTP/in-memory adapters.
- *True external*: Third-party APIs; injected port with mock test adapter.

**Vertical Slicing**:
An incremental implementation pattern where one failing test at a seam drives one minimal piece of end-to-end functionality (tracer bullet), rather than writing batches of speculative tests upfront.
_Avoid_: Horizontal slicing, bulk upfront test suites

**Implementation Coupling**:
A test anti-pattern where assertions spy on private helpers, intermediate tables, or internal call counts rather than observable public outcomes.
_Avoid_: Mocking internal module collaborators

**Tautological Test**:
A test assertion that recomputes expected values using the exact same algorithm or formulas as the production code under test, guaranteeing it passes by construction.
_Avoid_: Asserting against re-derived formulas instead of known independent literals

**Two-Axis Review**:
A code review discipline that separates evaluation into two independent, parallel sub-agent streams: **Standards** (adherence to repo rules and Fowler code smells) and **Spec** (fidelity to requirements and avoidance of scope creep).
_Avoid_: Blended monolithic review where formatting debates obscure broken requirements

**Standards Axis**:
Review focus that evaluates whether changes comply with documented repo guidelines (`AGENTS.md`, `CODING_STANDARDS.md`) and classic smell baselines (Middle Man, Speculative Generality, Feature Envy).

**Spec Axis**:
Review focus that evaluates whether changes faithfully implement the issue requirements, omit unrequested scope creep, and avoid subtle domain deviations.

**Context Load**:
The permanent cost of always-loaded material on the agent's attention and context window every turn (e.g., `AGENTS.md` lines, always-injected skill descriptions).

**Cognitive Load**:
The mental cost on the human engineer to remember which tools, slash commands, and documents exist and when to reach for each.

**Context Pointer**:
A reference in the agent's context that names out-of-context material and encodes the exact conditions/branches for loading it (e.g., a skill's description).

**Progressive Disclosure**:
Structuring agent knowledge so that only lightweight pointers are loaded initially, with detailed reference files pulled into context strictly on demand.

**Leading Word**:
A compact term already rich in pretrained model priors (e.g. *tight*, *red*, *tracer bullet*, *relentless*) that anchors complex behavior in a single token.

## Domain Terms

**Deal**:
A single ingested product offer (`DealScout.Deals.Deal`) with title, clean description text, price, temperature score, merchant, source feed, and optional `canonical_deal_id` linking duplicate offers.

**Alert rule**:
A user's saved monitoring query (`DealScout.Alerts.AlertRule`) combining a boolean keyword expression, negative keywords, and structured filters (price ceiling, minimum temperature, feed/merchant/country filters, dropshipper and foreign-keyboard exclusions) plus notification preferences (`cooldown_minutes`, `delivery_mode`).

**Keyword query**:
The single boolean keyword language (`DealScout.KeywordEngine.Query`) used across changeset validation, compiled Aho-Corasick matching, single-deal evaluation, negative keyword exclusion, and FTS5 candidate query generation.

**Match**:
A recorded hit (`DealScout.Alerts.UserMatch`) linking a user, an Alert rule, and a matching Deal in the user's real-time inbox and notification pipeline.

**Match evaluation**:
The pure decision module (`DealScout.Alerts.Evaluation`) that determines which `(Alert rule, Deal)` pairs match in a batch, hiding cross-border enrichment, the compiled Aho-Corasick prefilter, fallback evaluation for uncompiled or draft rules, structured filters, and negative keyword exclusions.

**Backtest**:
Historical preview (`DealScout.Alerts.Backtest`) that runs a saved or draft Alert rule against recent Deals (sourced via SQLite FTS5 or recent-deal fallback) using **Match evaluation** without triggering the **Compute guard** or notifications.

**Compute guard**:
The per-rule evaluation wrapper (`DealScout.Alerts.ComputeGuard`) that measures evaluation latency normalized per deal, emits telemetry, records slow runs to the NDJSON evaluation log, updates `last_eval_duration_us`, and auto-pauses rules that exceed the compute budget.

**Cooldown**:
A quiet window (`cooldown_minutes` on an Alert rule) after a notification during which new Matches are still broadcast to the LiveView inbox in real time, but push and email notifications are suppressed.

**Digest**:
A batched notification delivery mode (`delivery_mode` on an Alert rule, e.g. `"hourly_digest"` or `"daily_digest"`) that aggregates new Matches into a single periodic summary instead of sending instant alerts.

**Match delivery**:
The notification lifecycle (`DealScout.Notifications.Dispatcher`) that broadcasts every new Match to the LiveView inbox in real time, enforces **Cooldown**, collapses instant multi-deal batches, queues and flushes **Digest** summaries, and records actual push and email delivery outcomes.
_Avoid_: Caller-side cooldown branching, scattered dispatch helpers

**Compiled keyword index**:
The in-memory Aho-Corasick automaton and cost-pruned inverted index (`DealScout.KeywordEngine`) built from active Alert rules that prefilters candidate rules across a Deal batch in a single pass.
_Avoid_: Exposing raw `:persistent_term` maps or rule tuples across seams

**Replica sync**:
The real-time Litestream WAL/snapshot replication and atomic SQLite snapshot subsystem (`DealScout.Backup`) that authenticates backup clients, validates and streams missing replica frames, creates hot database snapshots, and reports replication lag.
_Avoid_: Scattering filesystem and snapshot SQL across web channels and controllers
