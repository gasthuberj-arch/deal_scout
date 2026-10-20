defmodule DealScoutWeb.PWAComponents do
  @moduledoc """
  UI components for PWA installation, push notification enrollment,
  and iOS installation guidance.
  """
  use Phoenix.Component
  import DealScoutWeb.CoreComponents

  attr :push_subscribed, :boolean, default: false
  attr :push_supported, :boolean, default: true
  attr :is_ios, :boolean, default: false
  attr :is_standalone, :boolean, default: false
  attr :show_ios_modal, :boolean, default: false
  attr :dismissed, :boolean, default: false

  def push_install_banner(assigns) do
    ~H"""
    <div id="pwa-push-container" phx-hook="PushManager" class="w-full">
      <%= if !@dismissed && @push_supported && !@push_subscribed do %>
        <div class="bg-gradient-to-r from-primary/15 via-primary/10 to-base-200 border border-primary/20 rounded-2xl p-4 sm:p-5 shadow-sm transition-all duration-200">
          <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
            <div class="flex items-start gap-3">
              <div class="size-10 rounded-xl bg-primary text-primary-content flex items-center justify-center shrink-0 shadow-md">
                <.icon name="hero-bell-alert" class="size-6" />
              </div>
              <div>
                <h3 class="font-bold text-sm sm:text-base text-base-content flex items-center gap-2">
                  Get Deal Alarms on your Phone
                  <%= if @is_ios && !@is_standalone do %>
                    <span class="badge badge-xs badge-outline">iOS PWA</span>
                  <% end %>
                </h3>
                <p class="text-xs sm:text-sm text-base-content/70 mt-0.5 max-w-xl">
                  Receive instant mobile push notifications whenever a hot deal matches your alert rules—no app store download required.
                </p>
              </div>
            </div>

            <div class="flex items-center gap-2 self-end sm:self-center shrink-0">
              <button
                phx-click="dismiss_push_banner"
                class="btn btn-ghost btn-xs text-base-content/60"
                title="Dismiss"
              >
                Later
              </button>
              <%= if @is_ios && !@is_standalone do %>
                <button
                  phx-click="open_ios_modal"
                  class="btn btn-primary btn-sm flex items-center gap-1.5 shadow-sm"
                >
                  <.icon name="hero-device-phone-mobile" class="size-4" />
                  <span>Install on iPhone</span>
                </button>
              <% else %>
                <button
                  phx-click="enable_push_notifications"
                  class="btn btn-primary btn-sm flex items-center gap-1.5 shadow-sm"
                >
                  <.icon name="hero-bell" class="size-4" />
                  <span>Enable Alarms</span>
                </button>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>

      <!-- iOS Installation Instructions Modal -->
      <%= if @show_ios_modal do %>
        <div
          id="ios-install-modal"
          class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/60 backdrop-blur-sm animate-fade-in"
        >
          <div class="card bg-base-100 w-full max-w-md shadow-2xl border border-base-300">
            <div class="p-6 space-y-4">
              <div class="flex items-center justify-between pb-3 border-b border-base-200">
                <div class="flex items-center gap-2">
                  <div class="size-8 rounded-lg bg-primary/10 text-primary flex items-center justify-center">
                    <.icon name="hero-device-phone-mobile" class="size-5" />
                  </div>
                  <h3 class="font-bold text-base text-base-content">Install DealScout on iOS</h3>
                </div>
                <button phx-click="close_ios_modal" class="btn btn-ghost btn-circle btn-sm">✕</button>
              </div>

              <p class="text-xs sm:text-sm text-base-content/80">
                Apple requires Progressive Web Apps to be added to the Home Screen to deliver background push alerts. Follow these 3 easy steps:
              </p>

              <div class="space-y-3 py-2 text-xs sm:text-sm">
                <div class="flex items-start gap-3 bg-base-200/60 p-3 rounded-xl border border-base-300/50">
                  <span class="size-6 rounded-full bg-primary text-primary-content text-xs font-bold flex items-center justify-center shrink-0">1</span>
                  <div>
                    <span class="font-semibold text-base-content">Tap the Share button</span>
                    <p class="text-base-content/70 text-xs mt-0.5">
                      In Safari's bottom toolbar, tap the square icon with an arrow pointing up.
                    </p>
                  </div>
                </div>

                <div class="flex items-start gap-3 bg-base-200/60 p-3 rounded-xl border border-base-300/50">
                  <span class="size-6 rounded-full bg-primary text-primary-content text-xs font-bold flex items-center justify-center shrink-0">2</span>
                  <div>
                    <span class="font-semibold text-base-content">Select "Add to Home Screen"</span>
                    <p class="text-base-content/70 text-xs mt-0.5">
                      Scroll down in the share sheet and tap <strong>Add to Home Screen</strong>.
                    </p>
                  </div>
                </div>

                <div class="flex items-start gap-3 bg-base-200/60 p-3 rounded-xl border border-base-300/50">
                  <span class="size-6 rounded-full bg-primary text-primary-content text-xs font-bold flex items-center justify-center shrink-0">3</span>
                  <div>
                    <span class="font-semibold text-base-content">Open DealScout from Home Screen</span>
                    <p class="text-base-content/70 text-xs mt-0.5">
                      Launch DealScout from your phone's Home Screen and tap <strong>Enable Alarms</strong>.
                    </p>
                  </div>
                </div>
              </div>

              <div class="pt-2 flex justify-end">
                <button phx-click="close_ios_modal" class="btn btn-primary btn-sm w-full">Got it</button>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
