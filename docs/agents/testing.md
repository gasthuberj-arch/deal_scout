# Testing Guidelines

Reference for testing LiveViews, Ecto queries, and concurrent OTP processes.

---

## 1. LiveView Testing (`Phoenix.LiveViewTest`)

- **Element-driven assertions**: Assert on semantic HTML elements and unique IDs rather than raw text or fragile CSS structures:
  ```elixir
  assert has_element?(view, "#deal-card-#{deal.id}")
  assert element(view, "#alert-form") |> render() =~ "Save"
  ```
- **Form interaction**:
  ```elixir
  view
  |> form("#alert-form", alert_rule: %{title: "RTX 4080", max_price: 900})
  |> render_submit()
  ```
- **Event testing**:
  ```elixir
  view
  |> element("button#toggle-dropshippers")
  |> render_click()
  ```
- **Debugging selectors**: Use `LazyHTML` rather than dumping huge HTML strings:
  ```elixir
  html = render(view)
  document = LazyHTML.from_fragment(html)
  matches = LazyHTML.filter(document, "#my-target")
  IO.inspect(matches, label: "Matches")
  ```

---

## 2. Process & Concurrency Testing

- **Supervision**: Always use `start_supervised!/1` to start GenServers, Task supervisors, or DynamicSupervisors in tests to guarantee automatic cleanup between test cases.
- **No arbitrary sleep**: Never use `Process.sleep/1` or `Process.alive?/1` to wait for asynchronous background work.
  - Monitor the process and assert on its exit signal:
    ```elixir
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    ```
  - For GenServer message processing synchronization, query state synchronously:
    ```elixir
    _ = :sys.get_state(server_pid)
    ```

---

## 3. Database Sandbox in Tests

- Tests that interact with the database must use `use DealScout.DataCase`.
- SQLite in test runs with sandbox mode; concurrent tests must use explicit ownership checkout if spawning detached async Tasks:
  ```elixir
  Ecto.Adapters.SQL.Sandbox.allow(DealScout.Repo, self(), task_pid)
  ```
