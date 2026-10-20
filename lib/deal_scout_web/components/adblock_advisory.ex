defmodule DealScoutWeb.Components.AdblockAdvisory do
  @moduledoc """
  Renders an educational, dismissible ad blocker advisory banner.
  Only displays via the AdBlockDetector JS hook if an ad blocker is actively running,
  informing the user that affiliate bargain redirects and push alarms might be blocked.
  """
  use Phoenix.Component
  import DealScoutWeb.CoreComponents, only: [icon: 1]

  @doc """
  Renders the educational adblock banner with AdBlockDetector hook.
  """
  def adblock_banner(assigns) do
    ~H"""
    <aside
      id="adblock-banner"
      phx-hook="AdBlockDetector"
      hidden
      class="bg-amber-500/10 border border-amber-500/30 rounded-2xl p-4 sm:p-5 text-amber-900 dark:text-amber-100 transition-all duration-300 shadow-sm"
      role="status"
      aria-live="polite"
    >
      <div class="flex items-start gap-3.5">
        <div class="size-9 rounded-xl bg-amber-500/20 text-amber-600 dark:text-amber-400 flex items-center justify-center shrink-0 mt-0.5">
          <.icon name="hero-shield-exclamation" class="size-5" />
        </div>

        <div class="flex-1 min-w-0 space-y-1">
          <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-2">
            <h3 class="font-bold text-sm sm:text-base flex items-center gap-2">
              <span>Ad blocker active: bargain redirects &amp; alarms might be affected</span>
              <span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-semibold uppercase bg-amber-500/20 text-amber-800 dark:text-amber-300">Good to know</span>
            </h3>
            <button
              id="adblock-dismiss-btn"
              type="button"
              class="px-2 py-1 rounded text-xs text-stone-500 dark:text-stone-400 hover:text-stone-900 dark:hover:text-stone-100 hover:bg-amber-500/20 transition-colors self-end sm:self-center cursor-pointer"
            >
              Got it
            </button>
          </div>
          <p class="text-xs sm:text-sm text-base-content/75 leading-relaxed">
            DealScout doesn't show any third-party ads, so you don't need to disable your ad blocker everywhere. However, bargain feeds (like MyDealz or Idealo) route through affiliate redirects that ad blockers often block. If clicking a deal shows a blank page or push alarms fail to register, your ad blocker is in the way.
          </p>
        </div>
      </div>
    </aside>
    """
  end
end
