defmodule DealScoutWeb.Components.SupportModal do
  @moduledoc """
  Encapsulates the independent project support / tipping modal and attribution footer.
  Provides payment rail URL resolution and Phoenix LiveView JS commands for modal visibility.
  """
  use Phoenix.Component
  import DealScoutWeb.CoreComponents, only: [icon: 1]
  alias Phoenix.LiveView.JS

  @doc """
  Shows the coffee support modal via Phoenix LiveView JS commands.
  """
  def show_coffee_modal(js \\ %JS{}) do
    js
    |> JS.remove_attribute("hidden", to: "#coffee-modal")
    |> JS.show(to: "#coffee-modal", display: "block")
    |> JS.add_class("overflow-hidden", to: "body")
  end

  @doc """
  Hides the coffee support modal via Phoenix LiveView JS commands.
  """
  def hide_coffee_modal(js \\ %JS{}) do
    js
    |> JS.hide(to: "#coffee-modal")
    |> JS.remove_class("overflow-hidden", to: "body")
  end

  @doc """
  Resolves the coffee / support URL. If COFFEE_URL is set, it overrides all rails.
  Otherwise, falls back to the canonical URL for each rail.
  """
  def coffee_url(rail \\ :default) do
    case {System.get_env("COFFEE_URL"), rail} do
      {url, _} when is_binary(url) and url != "" -> url
      {_, :kofi} -> "https://ko-fi.com"
      {_, :buymeacoffee} -> "https://buymeacoffee.com"
      {_, :paypal} -> "https://paypal.me"
      {_, :github} -> "https://github.com/sponsors"
      _ -> "https://ko-fi.com"
    end
  end

  @doc """
  Renders the application footer with project attribution and support modal trigger.
  """
  def footer(assigns) do
    ~H"""
    <footer class="mt-auto border-t border-base-200 py-6 text-center text-xs text-base-content/60">
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 flex flex-col sm:flex-row items-center justify-between gap-3">
        <p>
          DealScout &mdash; Private, real-time deal monitoring with zero tracking.
        </p>
        <button
          type="button"
          phx-click={show_coffee_modal()}
          class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-amber-500/30 bg-amber-500/10 text-amber-600 dark:text-amber-400 font-medium hover:bg-amber-500/20 transition-colors cursor-pointer"
        >
          <span>☕</span>
          <span>Support the project</span>
        </button>
      </div>
    </footer>
    """
  end

  @doc """
  Renders an interactive support modal letting users choose their preferred tip / donation rail.
  Built with custom Tailwind styling and Phoenix JS commands (zero DaisyUI modal dependencies).
  """
  def coffee_modal(assigns) do
    ~H"""
    <div
      id="coffee-modal"
      style="display: none;"
      class="fixed inset-0 z-50 overflow-y-auto"
      role="dialog"
      aria-modal="true"
    >
      <div
        class="fixed inset-0 bg-neutral-900/60 backdrop-blur-xs transition-opacity cursor-pointer"
        phx-click={hide_coffee_modal()}
      />

      <div class="flex min-h-full items-center justify-center p-4 text-center">
        <div class="relative w-full max-w-md transform overflow-hidden rounded-2xl bg-base-100 p-6 text-left shadow-2xl border border-base-200 transition-all space-y-5">
          <button
            type="button"
            phx-click={hide_coffee_modal()}
            class="absolute right-4 top-4 text-base-content/50 hover:text-base-content p-1 rounded-lg hover:bg-base-200 transition-colors cursor-pointer"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>

          <div class="text-center space-y-2 pt-2">
            <div class="inline-flex size-12 rounded-2xl bg-amber-500/10 text-amber-500 items-center justify-center text-2xl mx-auto shadow-inner">
              ☕
            </div>
            <h3 class="font-bold text-lg text-base-content">
              Want to support an effort with no business model?
            </h3>
            <p class="text-xs text-base-content/70 leading-relaxed max-w-xs mx-auto">
              DealScout is an independent, private tool with <strong>zero ads, zero trackers, and zero affiliate hijacking</strong>.
              If DealScout just saved you money on a deal, choose your preferred rail:
            </p>
          </div>

          <div class="space-y-2">
            <a
              href={coffee_url(:kofi)}
              target="_blank"
              rel="noopener noreferrer"
              class="flex items-center justify-between p-3 rounded-xl border border-base-200 hover:border-amber-500/40 hover:bg-amber-500/5 transition-all group"
            >
              <div class="flex items-center gap-3">
                <span class="text-xl">☕</span>
                <div>
                  <div class="font-semibold text-sm flex items-center gap-1.5">
                    <span>Ko-fi</span>
                    <span class="text-[10px] font-medium px-1.5 py-0.5 rounded bg-emerald-500/10 text-emerald-600 dark:text-emerald-400">0% fee</span>
                  </div>
                  <div class="text-xs text-base-content/60">
                    Apple Pay, Google Pay, Card &amp; PayPal
                  </div>
                </div>
              </div>
              <.icon
                name="hero-arrow-top-right-on-square"
                class="size-4 text-base-content/40 group-hover:text-amber-500 transition-colors"
              />
            </a>

            <a
              href={coffee_url(:buymeacoffee)}
              target="_blank"
              rel="noopener noreferrer"
              class="flex items-center justify-between p-3 rounded-xl border border-base-200 hover:border-amber-500/40 hover:bg-amber-500/5 transition-all group"
            >
              <div class="flex items-center gap-3">
                <span class="text-xl">🟡</span>
                <div>
                  <div class="font-semibold text-sm">Buy Me a Coffee</div>
                  <div class="text-xs text-base-content/60">Classic one-click coffee tip</div>
                </div>
              </div>
              <.icon
                name="hero-arrow-top-right-on-square"
                class="size-4 text-base-content/40 group-hover:text-amber-500 transition-colors"
              />
            </a>

            <a
              href={coffee_url(:paypal)}
              target="_blank"
              rel="noopener noreferrer"
              class="flex items-center justify-between p-3 rounded-xl border border-base-200 hover:border-blue-500/40 hover:bg-blue-500/5 transition-all group"
            >
              <div class="flex items-center gap-3">
                <span class="text-xl">🅿️</span>
                <div>
                  <div class="font-semibold text-sm">PayPal.me</div>
                  <div class="text-xs text-base-content/60">Direct Friends &amp; Family transfer</div>
                </div>
              </div>
              <.icon
                name="hero-arrow-top-right-on-square"
                class="size-4 text-base-content/40 group-hover:text-blue-500 transition-colors"
              />
            </a>

            <a
              href={coffee_url(:github)}
              target="_blank"
              rel="noopener noreferrer"
              class="flex items-center justify-between p-3 rounded-xl border border-base-200 hover:border-purple-500/40 hover:bg-purple-500/5 transition-all group"
            >
              <div class="flex items-center gap-3">
                <span class="text-xl">🐙</span>
                <div>
                  <div class="font-semibold text-sm">GitHub Sponsors</div>
                  <div class="text-xs text-base-content/60">0% fee for open source developers</div>
                </div>
              </div>
              <.icon
                name="hero-arrow-top-right-on-square"
                class="size-4 text-base-content/40 group-hover:text-purple-500 transition-colors"
              />
            </a>
          </div>

          <div class="pt-2 text-center">
            <button
              type="button"
              phx-click={hide_coffee_modal()}
              class="text-xs text-base-content/60 hover:text-base-content transition-colors cursor-pointer"
            >
              Maybe next time
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
