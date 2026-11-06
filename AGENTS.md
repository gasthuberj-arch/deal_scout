# DealScout Agent Instructions

DealScout is a real-time RSS deal monitor and keyword alert system built with Elixir, Phoenix 1.8 LiveView, Tailwind CSS v4, and SQLite.

## Critical Invariants

- **Precommit check**: Always run `mix precommit` after completing changes and ensure all formatting, dialyzer, and test checks pass.
- **HTTP client**: Use `:req` (`Req`) for all HTTP requests. Do not introduce `:httpoison`, `:tesla`, or `:httpc`.
- **LiveView root layout**: Always wrap LiveView templates in `<Layouts.app flash={@flash} current_scope={@current_scope} ...>`.
- **Component primitives**: Use `<.icon name="hero-..." class="..." />` for icons and `<.input>` from `core_components.ex` for form controls.
- **User scope**: Always access the logged-in user via `@current_scope.user` (never `@current_user`). Pass `current_scope` as the first argument to context functions and scope all queries by user.
- **Styling**: Tailwind CSS v4 (`assets/css/app.css`). DaisyUI is available for basic components, but build custom Tailwind components for polished micro-interactions, dark mode, and responsive layouts. Never use `@apply` in raw CSS.

## Context Pointers (Progressive Disclosure)

Read the relevant reference document when entering a specific branch:

- **Phoenix & LiveView** (`docs/agents/phoenix.md`): Read when creating or modifying LiveViews, streams, forms, HEEx templates, or colocated JavaScript hooks (`.HookName`).
- **Authentication & Routing** (`docs/agents/authentication.md`): Read when adding routes, configuring router plugs (`:require_authenticated_user`), or managing `live_session` scopes.
- **Database & Schemas** (`docs/agents/database.md`): Read when writing Ecto schemas, SQLite queries, associations, or migrations.
- **Testing Patterns** (`docs/agents/testing.md`): Read when writing LiveView tests (`element/2`, `render_submit`), process synchronization, or OTP supervision tests.
- **Domain & Architecture** (`docs/agents/domain.md`): Read before exploring the codebase, defining domain terms in `GLOSSARY.md`, or consulting ADRs in `docs/adr/`.
- **Issue Tracker & Triage** (`docs/agents/issue-tracker.md`, `docs/agents/triage-labels.md`): Read when creating issues or managing triage workflows.
