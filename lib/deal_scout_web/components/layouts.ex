defmodule DealScoutWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use DealScoutWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar border-b border-base-300 bg-base-100/90 backdrop-blur sticky top-0 z-50 px-4 sm:px-6 lg:px-8">
      <div class="navbar-start flex items-center gap-2">
        <.link
          navigate={~p"/"}
          class="flex items-center gap-2 font-black text-xl tracking-tight text-primary hover:opacity-80 transition-opacity"
        >
          <span class="p-1.5 rounded-lg bg-primary/10 text-primary">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="size-5"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2.5"
                d="M13 10V3L4 14h7v7l9-11h-7z"
              />
            </svg>
          </span>
          <span>DealScout</span>
          <span class="badge badge-primary badge-outline badge-xs text-[10px] font-mono uppercase tracking-wider">Live</span>
        </.link>
      </div>

      <div class="navbar-center hidden md:flex">
        <ul class="menu menu-horizontal gap-1 font-medium text-sm">
          <li>
            <.link navigate={~p"/"} class="rounded-lg">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="size-4"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M19 20H5a2 2 0 01-2-2V6a2 2 0 012-2h10a2 2 0 012 2v1m2 13a2 2 0 01-2-2V7m2 13a2 2 0 002-2V9a2 2 0 00-2-2h-2m-4-3H9M7 16h6M7 8h6v4H7V8z"
                />
              </svg>
              Live Feed
            </.link>
          </li>
          <%= if @current_scope && @current_scope.user do %>
            <li>
              <.link navigate={~p"/alerts"} class="rounded-lg">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="size-4"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9"
                  />
                </svg>
                My Alert Keywords
              </.link>
            </li>
            <li>
              <.link navigate={~p"/matches"} class="rounded-lg flex items-center gap-1.5">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="size-4"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
                  />
                </svg>
                Matches
              </.link>
            </li>
            <li>
              <.link navigate={~p"/analytics"} class="rounded-lg flex items-center gap-1.5">
                <.icon name="hero-chart-bar-square" class="size-4" /> Analytics
              </.link>
            </li>
          <% end %>
        </ul>
      </div>

      <div class="navbar-end flex items-center gap-2">
        <.theme_toggle />
        <%= if @current_scope && @current_scope.user do %>
          <div class="dropdown dropdown-end">
            <div tabindex="0" role="button" class="btn btn-ghost btn-circle avatar placeholder">
              <div class="bg-primary text-primary-content rounded-full w-9">
                <span class="text-xs uppercase font-bold">{String.slice(
                  @current_scope.user.email,
                  0..1
                )}</span>
              </div>
            </div>
            <ul
              tabindex="0"
              class="mt-3 z-[1] p-2 shadow menu menu-sm dropdown-content bg-base-100 rounded-box w-56 border border-base-200"
            >
              <li class="menu-title text-xs truncate max-w-full px-2 py-1">
                {@current_scope.user.email}
              </li>
              <div class="divider my-1"></div>
              <li><.link navigate={~p"/alerts"}>My Alert Keywords</.link></li>
              <li><.link navigate={~p"/matches"}>Matched Deals</.link></li>
              <li><.link navigate={~p"/analytics"}>Deal Intelligence</.link></li>
              <%= if @current_scope.user.is_admin do %>
                <li>
                  <.link navigate={~p"/admin/system"} class="text-error font-medium">
                    <.icon name="hero-shield-check" class="size-3.5" /> Admin System Ops
                  </.link>
                </li>
              <% end %>
              <li><.link navigate={~p"/users/settings"}>Settings</.link></li>
              <div class="divider my-1"></div>
              <li>
                <.link href={~p"/users/log-out"} method="delete" class="text-error">Log out</.link>
              </li>
            </ul>
          </div>
        <% else %>
          <.link navigate={~p"/users/log-in"} class="btn btn-ghost btn-sm">Log in</.link>
          <.link navigate={~p"/users/register"} class="btn btn-primary btn-sm">Sign up</.link>
        <% end %>
      </div>
    </header>

    <main class="px-4 py-8 sm:px-6 lg:px-8 max-w-7xl mx-auto">
      <div class="space-y-6">
        <.adblock_banner />
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Renders an educational, dismissible ad blocker advisory banner.
  Only displays via the AdBlockDetector JS hook if an ad blocker is actively running,
  informing the user that affiliate bargain redirects and push alarms might be blocked.
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
              <span>Ad blocker active: bargain redirects & alarms might be affected</span>
              <span class="badge badge-warning badge-xs font-semibold uppercase">Good to know</span>
            </h3>
            <button
              id="adblock-dismiss-btn"
              type="button"
              class="btn btn-ghost btn-xs text-base-content/60 self-end sm:self-center hover:bg-amber-500/20"
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

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <%!-- Subtle, delayed live stream reconnection badge (avoids alarming red toasts during fast deploys) --%>
      <div
        id="reconnect-badge"
        phx-disconnected={JS.remove_attribute("hidden", to: "#reconnect-badge")}
        phx-connected={JS.set_attribute({"hidden", ""}, to: "#reconnect-badge")}
        hidden
        class="fixed bottom-4 right-4 z-50 pointer-events-none transition-all duration-300 [animation:fade-in_0.3s_ease-out_2s_both]"
      >
        <div class="flex items-center gap-2 px-3 py-1.5 rounded-full bg-base-100/95 text-base-content/80 text-xs font-medium shadow-lg backdrop-blur border border-base-content/10">
          <span class="size-2 rounded-full bg-warning animate-ping"></span>
          <span>{gettext("Reconnecting...")}</span>
          <.icon name="hero-arrow-path" class="size-3 animate-spin text-base-content/60" />
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
