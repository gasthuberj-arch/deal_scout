# Mission: Architecture & Design Skills in DealScout

## Why
Master how to design deep, robust software modules and rigorously evaluate architectural plans using agent skills (`codebase-design` and `grilling`), so that developing features in DealScout produces high leverage for callers, clear seams, and minimal tech debt.

## Success looks like
- Confidently applying the deep module vocabulary (Module, Interface, Implementation, Seam, Adapter, Depth, Leverage, Locality) to assess and refactor DealScout components.
- Identifying shallow modules and pass-throughs using the Deletion Test.
- Classifying dependencies (In-process, Local-substitutable, Remote but owned, True external) to position seams and adapters accurately.
- Using the "Design It Twice" parallel sub-agent pattern to explore and compare alternative interface shapes.
- Stress-testing architectural plans with the `grilling` skill using the decision-tree frontier before writing code.

## Constraints
- Focus on practical applicability to Elixir and Phoenix LiveView patterns in DealScout.
- High-signal, interactive lessons with minimal cognitive overload.
- Keep lessons fast to complete with immediate interactive feedback.

## Out of scope
- Low-level Elixir/Phoenix syntax boilerplate already documented in AGENTS.md.
- Agent internals and skill authoring mechanics not required for day-to-day architecture.
