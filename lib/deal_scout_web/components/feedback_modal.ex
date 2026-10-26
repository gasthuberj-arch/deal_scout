defmodule DealScoutWeb.Components.FeedbackModal do
  @moduledoc """
  Renders a floating feedback button and modal dialog for authenticated users.
  Handles submission lifecycle, form preservation on errors, and rate limit responses.
  """
  use Phoenix.Component
  import DealScoutWeb.CoreComponents, only: [icon: 1, button: 1]
  alias Phoenix.LiveView.JS

  @doc """
  Shows the feedback modal via Phoenix LiveView JS commands.
  """
  def show_feedback_modal(js \\ %JS{}) do
    js
    |> JS.show(to: "#feedback-modal")
    |> JS.add_class("overflow-hidden", to: "body")
    |> JS.focus(to: "#feedback-message")
  end

  @doc """
  Hides the feedback modal via Phoenix LiveView JS commands.
  """
  def hide_feedback_modal(js \\ %JS{}) do
    js
    |> JS.hide(to: "#feedback-modal")
    |> JS.remove_class("overflow-hidden", to: "body")
  end

  @doc """
  LiveView lifecycle handle_event hook for processing feedback submissions.
  Keeps feedback event logic encapsulated away from UserAuth.
  """
  def handle_event("submit_feedback", params, socket) do
    feedback_params = Map.get(params, "feedback", params)
    current_scope = socket.assigns[:current_scope]

    if current_scope && current_scope.user do
      case DealScout.Feedback.create_feedback(current_scope, feedback_params) do
        {:ok, _feedback} ->
          socket =
            socket
            |> Phoenix.LiveView.put_flash(
              :info,
              "Thank you for your feedback! Our team has received your message."
            )
            |> Phoenix.LiveView.push_event("feedback-submitted", %{})

          {:halt, socket}

        {:error, :rate_limited} ->
          socket =
            socket
            |> Phoenix.LiveView.put_flash(
              :error,
              "You have submitted feedback multiple times recently. Please wait a bit before sending more."
            )

          {:halt, socket}

        {:error, %Ecto.Changeset{} = changeset} ->
          errors =
            changeset
            |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
            |> Enum.map(fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
            |> Enum.join("; ")

          socket =
            socket
            |> Phoenix.LiveView.put_flash(:error, "Could not send feedback: #{errors}")

          {:halt, socket}
      end
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must be signed in to submit feedback.")

      {:halt, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:cont, socket}

  @doc """
  Renders the floating feedback button and modal dialog.
  Only rendered when @current_scope.user is authenticated.
  """
  attr :current_scope, :map, default: nil

  def feedback_widget(assigns) do
    ~H"""
    <div :if={@current_scope && @current_scope.user} id="feedback-widget-container">
      <%!-- Floating Feedback Pill Button --%>
      <button
        id="feedback-trigger-btn"
        type="button"
        phx-click={show_feedback_modal()}
        class="group fixed bottom-5 right-5 z-40 inline-flex items-center gap-2 px-3.5 py-2.5 rounded-full bg-base-900 text-white dark:bg-primary dark:text-primary-content shadow-lg hover:shadow-xl hover:scale-105 active:scale-95 transition-all duration-200 border border-white/10 cursor-pointer font-medium text-xs sm:text-sm"
        title="Give feedback"
      >
        <span class="inline-flex items-center justify-center size-5 rounded-full bg-white/20 group-hover:rotate-12 transition-transform">
          <.icon name="hero-chat-bubble-bottom-center-text" class="size-3.5" />
        </span>
        <span>Feedback</span>
      </button>

      <%!-- Modal Dialog Container --%>
      <div id="feedback-modal-wrapper" phx-hook=".FeedbackHook">
        <div
          id="feedback-modal"
          hidden
          class="fixed inset-0 z-50 overflow-y-auto"
          role="dialog"
          aria-modal="true"
          phx-window-keydown={hide_feedback_modal()}
          phx-key="Escape"
        >
          <%!-- Backdrop --%>
          <div
            class="fixed inset-0 bg-neutral-900/60 backdrop-blur-xs transition-opacity cursor-pointer"
            phx-click={hide_feedback_modal()}
          />

          <div class="flex min-h-full items-center justify-center p-4 text-center">
            <div class="relative w-full max-w-lg transform overflow-hidden rounded-2xl bg-base-100 p-6 text-left shadow-2xl border border-base-200 transition-all space-y-4">
              <button
                type="button"
                phx-click={hide_feedback_modal()}
                class="absolute right-4 top-4 text-base-content/50 hover:text-base-content p-1.5 rounded-lg hover:bg-base-200 transition-colors cursor-pointer"
                aria-label="Close"
              >
                <.icon name="hero-x-mark" class="size-5" />
              </button>

              <div class="flex items-center gap-3">
                <div class="size-10 rounded-xl bg-primary/10 text-primary flex items-center justify-center shrink-0">
                  <.icon name="hero-chat-bubble-bottom-center-text" class="size-6" />
                </div>
                <div>
                  <h3 class="font-bold text-lg text-base-content">
                    Send Feedback
                  </h3>
                  <p class="text-xs text-base-content/70">
                    Help us improve DealScout. Let us know about bugs, scraper quirks, or ideas!
                  </p>
                </div>
              </div>

              <.form
                for={%{}}
                as={:feedback}
                id="feedback-form"
                phx-submit="submit_feedback"
                class="space-y-4 pt-2"
              >
                <input
                  type="text"
                  name="feedback[page_url]"
                  id="feedback-page-url"
                  class="hidden"
                  tabindex="-1"
                  aria-hidden="true"
                />

                <div class="space-y-1.5">
                  <label
                    for="feedback-category"
                    class="block text-xs font-semibold uppercase tracking-wider text-base-content/70"
                  >
                    Category
                  </label>
                  <select
                    id="feedback-category"
                    name="feedback[category]"
                    required
                    class="select select-bordered w-full text-sm rounded-xl bg-base-200/50 focus:bg-base-100"
                  >
                    <option value="bug">🐛 Bug Report</option>
                    <option value="feature_request">💡 Feature Request</option>
                    <option value="scraper_issue">🔍 Deal / Scraper Issue</option>
                    <option value="other" selected>💬 General Feedback / Other</option>
                  </select>
                </div>

                <div class="space-y-1.5">
                  <label
                    for="feedback-message"
                    class="block text-xs font-semibold uppercase tracking-wider text-base-content/70"
                  >
                    Your Message
                  </label>
                  <textarea
                    id="feedback-message"
                    name="feedback[message]"
                    rows="4"
                    required
                    minlength="5"
                    maxlength="2000"
                    placeholder="What's on your mind? Detailed feedback helps us fix bugs and build better deal monitors."
                    class="textarea textarea-bordered w-full text-sm rounded-xl bg-base-200/50 focus:bg-base-100 leading-relaxed"
                  ></textarea>
                  <p class="text-[11px] text-base-content/50 text-right">
                    Max 2,000 characters
                  </p>
                </div>

                <div class="flex items-center justify-end gap-3 pt-2">
                  <button
                    type="button"
                    phx-click={hide_feedback_modal()}
                    class="btn btn-ghost btn-sm text-base-content/70 hover:text-base-content cursor-pointer"
                  >
                    Cancel
                  </button>
                  <.button
                    type="submit"
                    id="feedback-submit-btn"
                    phx-disable-with="Submitting..."
                    class="btn btn-primary btn-sm px-5 gap-2 shadow-sm cursor-pointer"
                  >
                    <.icon name="hero-paper-airplane" class="size-4" /> Submit Feedback
                  </.button>
                </div>
              </.form>
            </div>
          </div>
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".FeedbackHook">
          export default {
            mounted() {
              const populateUrl = () => {
                const input = this.el.querySelector('#feedback-page-url');
                if (input) {
                  input.value = window.location.pathname + window.location.search;
                }
              };

              populateUrl();
              window.addEventListener('phx:page-loading-stop', populateUrl);

              this.handleEvent('feedback-submitted', () => {
                const form = this.el.querySelector('#feedback-form');
                if (form) form.reset();
                populateUrl();

                const modal = document.querySelector('#feedback-modal');
                if (modal) modal.hidden = true;
                document.body.classList.remove('overflow-hidden');
              });
            }
          }
        </script>
      </div>
    </div>
    """
  end
end
