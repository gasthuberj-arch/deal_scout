# Phoenix & LiveView Guidelines

Reference for creating and modifying Phoenix LiveView views, components, HEEx templates, and JavaScript interop.

---

## 1. Templates & Layouts

- **Root wrapper**: Always wrap LiveView templates in `<Layouts.app flash={@flash} current_scope={@current_scope} ...>` which wraps all inner content.
- **Layouts module**: `MyAppWeb.Layouts` is aliased in `my_app_web.ex`. Use `<Layouts.app>` directly.
- **Flash component**: `<.flash_group>` belongs strictly to `layouts.ex`. Never invoke `<.flash_group>` outside of the `layouts.ex` module.
- **Icons**: Out of the box, `core_components.ex` imports `<.icon name="hero-..." class="..." />`. Always use `<.icon>` instead of direct Heroicons modules.
- **Inputs**: Always use imported `<.input>` from `core_components.ex` for forms. If custom classes are provided, they replace default styling completely.
- **HEEx interpolation**:
  - Use `{...}` for attribute and textual expression interpolation.
  - Use `<%= ... %>` exclusively for block constructs (`if`, `cond`, `case`, `for`) within tag bodies.
  - Use `phx-no-curly-interpolation` attribute on parent tags (e.g. `<pre>` or `<code>`) to display literal `{` or `}` characters without escaping.
  - Dynamic class lists require list syntax: `class={["base-class", @active && "is-active", if(@cond, do: "a", else: "b")]}`.

---

## 2. LiveView Streams

Always use LiveView streams for collections to keep memory constant and avoid ballooning the BEAM heap:

- **Stream operations**:
  - Append items: `stream(socket, :messages, [new_msg])`
  - Reset stream (filter/sort): `stream(socket, :messages, items, reset: true)`
  - Prepend items: `stream(socket, :messages, [new_msg], at: -1)`
  - Delete items: `stream_delete(socket, :messages, msg)`
  - Update items: `stream_insert(socket, :messages, updated_msg)`

- **Template consumption**:
  - Always set `phx-update="stream"` with a unique DOM id on the parent element.
  - Consume via `<div :for={{dom_id, item} <- @streams.collection} id={dom_id}>`.

  ```heex
  <div id="deals" phx-update="stream">
    <div :for={{dom_id, deal} <- @streams.deals} id={dom_id}>
      <.deal_card deal={deal} />
    </div>
  </div>
  ```

- **Empty states & counts**: Streams are not enumerable (`Enum.count` / `Enum.filter` do not work). Track counts via a separate socket assign. For CSS-only empty states, use Tailwind's `only:block`:
  ```heex
  <div id="deals" phx-update="stream">
    <div class="hidden only:block text-zinc-500">No deals found</div>
    <div :for={{dom_id, deal} <- @streams.deals} id={dom_id}>...</div>
  </div>
  ```

---

## 3. Form Handling

- **Changeset-driven forms**: Assign forms in LiveView via `to_form/2` and bind via `<.form for={@form} id="unique-form-id">`:
  ```elixir
  # LiveView
  form = to_form(Alerts.change_alert_rule(%AlertRule{}))
  {:ok, assign(socket, form: form)}
  ```
  ```heex
  <%!-- Template --%>
  <.form for={@form} id="alert-form" phx-change="validate" phx-submit="save">
    <.input field={@form[:title]} type="text" label="Rule Name" />
  </.form>
  ```
- **Form params**: When assigning from params in `handle_event`:
  ```elixir
  def handle_event("validate", %{"alert_rule" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: :alert_rule))}
  end
  ```
- **Rule**: Never pass a raw `%Ecto.Changeset{}` directly to `<.form for={@changeset}>` or access changeset fields in templates. Always pass a `Phoenix.HTML.Form` created via `to_form/2`.

---

## 4. JavaScript Interop & Hooks

- **Colocated hooks** (preferred for component-specific scripts):
  Must start with a leading dot (`.`):
  ```heex
  <div id="audio-chime" phx-hook=".AudioChime"></div>
  <script :type={Phoenix.LiveView.ColocatedHook} name=".AudioChime">
    export default {
      mounted() {
        this.handleEvent("play_chime", () => this.play())
      }
    }
  </script>
  ```
- **DOM management**: If a hook mutates its own DOM elements, add `phx-update="ignore"` to the container.
- **Client-server communication**:
  - Push from server: `push_event(socket, "event_name", payload)` (handled by `this.handleEvent` in hook).
  - Push from client: `this.pushEvent("event_name", payload, reply => ...)` (handled by `handle_event/3` in LiveView).
