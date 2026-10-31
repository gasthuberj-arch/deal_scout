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
  Resolves the Ko-fi support URL from `COFFEE_URL`, falling back to `https://ko-fi.com`.
  """
  def coffee_url do
    case System.get_env("COFFEE_URL") do
      url when is_binary(url) and url != "" -> url
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
  Renders an interactive support modal linking to Ko-fi.
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
              If DealScout just saved you money on a deal, you can support the project on Ko-fi:
            </p>
          </div>

          <div class="space-y-2.5 pt-1">
            <a
              id="kofi-support-link"
              href={coffee_url()}
              target="_blank"
              rel="noopener noreferrer"
              class="flex items-center justify-center gap-2.5 w-full py-3 px-5 rounded-xl bg-[#72a4f2] hover:bg-[#5e92e6] text-white font-semibold text-sm shadow-md hover:shadow-lg transition-all group"
            >
              <span class="text-lg leading-none group-hover:scale-110 transition-transform">☕</span>
              <span>Support DealScout on Ko-fi</span>
              <.icon
                name="hero-arrow-top-right-on-square"
                class="size-4 text-white/80 group-hover:text-white transition-colors"
              />
            </a>
            <div class="flex items-center justify-center gap-2 text-[11px] text-base-content/60">
              <span class="font-medium px-1.5 py-0.5 rounded bg-emerald-500/10 text-emerald-600 dark:text-emerald-400">
                0% platform fee
              </span>
              <span>•</span>
              <span>Apple Pay, Google Pay, Card &amp; PayPal</span>
            </div>
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
