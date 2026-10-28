defmodule DealScoutWeb.LegalLive.Impressum do
  use DealScoutWeb, :live_view

  alias DealScout.Legal

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Impressum")
      |> assign(:operator_name, Legal.operator_name())
      |> assign(:operator_email, Legal.operator_email())
      |> assign(:operator_address, Legal.operator_address())

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-4xl mx-auto space-y-8 py-4">
        <%!-- Header --%>
        <div class="bg-base-200/50 p-6 sm:p-8 rounded-2xl border border-base-300">
          <div class="flex items-center gap-3">
            <span class="p-2.5 rounded-xl bg-primary/10 text-primary">
              <.icon name="hero-scale" class="size-6" />
            </span>
            <div>
              <h1 class="text-2xl sm:text-3xl font-extrabold tracking-tight">Impressum</h1>
              <p class="text-xs sm:text-sm text-base-content/70 mt-0.5">
                Angaben gemäß § 5 Digitale-Dienste-Gesetz (DDG)
              </p>
            </div>
          </div>
        </div>

        <%!-- Betreiber / Diensteanbieter --%>
        <div class="card bg-base-100 border border-base-300 p-6 sm:p-8 rounded-2xl shadow-sm space-y-4">
          <h2 class="text-lg font-bold text-base-content flex items-center gap-2">
            <.icon name="hero-user" class="size-5 text-primary" />
            <span>Diensteanbieter / Betreiber</span>
          </h2>
          <div class="text-sm text-base-content/80 space-y-1">
            <p id="operator-name" class="font-semibold text-base-content">{@operator_name}</p>
            <p id="operator-address">{@operator_address}</p>
          </div>

          <div class="divider my-2"></div>

          <h3 class="text-sm font-semibold text-base-content uppercase tracking-wider text-xs">
            Kontakt
          </h3>
          <p class="text-sm text-base-content/80 flex items-center gap-2">
            <.icon name="hero-envelope" class="size-4 text-base-content/60" />
            <a
              id="operator-email"
              href={"mailto:#{@operator_email}"}
              class="link link-primary font-mono text-xs sm:text-sm"
            >
              {@operator_email}
            </a>
          </p>
        </div>

        <%!-- Zweck & Haftungsausschluss --%>
        <div class="card bg-base-100 border border-base-300 p-6 sm:p-8 rounded-2xl shadow-sm space-y-6">
          <div>
            <h2 class="text-lg font-bold text-base-content flex items-center gap-2">
              <.icon name="hero-information-circle" class="size-5 text-primary" />
              <span>Haftungsausschluss für Deal-Inhalte &amp; externe Links</span>
            </h2>
            <div class="text-sm text-base-content/80 space-y-3 mt-3 leading-relaxed">
              <p>
                DealScout ist ein technischer Aggregator, der öffentlich zugängliche RSS-Feeds deutscher und europäischer Deal-Plattformen
                (z. B. MyDealz, DealDoktor, MonsterDealz, Schnäppchenfuchs, Mein-Deal) in Echtzeit sammelt, dedupliziert und filtert.
              </p>
              <p>
                Die auf dieser Plattform dargestellten Produktbezeichnungen, Deal-Preise, Händlerangaben und Verfügbarkeiten stammen
                vollständig von den jeweiligen Drittanbietern und Deal-Portalen. Wir übernehmen keine Gewähr für die Richtigkeit, Vollständigkeit
                oder Aktualität der externen Angebote. Maßgeblich sind stets die Preise und Konditionen im Ziel-Shop des jeweiligen Händlers.
              </p>
              <p>
                Unser Angebot enthält Links zu externen Websites Dritter, auf deren Inhalte wir keinen Einfluss haben. Deshalb können wir für
                diese fremden Inhalte auch keine Gewähr übernehmen. Für die Inhalte der verlinkten Seiten ist stets der jeweilige Anbieter
                oder Betreiber der Seiten verantwortlich.
              </p>
            </div>
          </div>

          <div class="divider my-0"></div>

          <div>
            <h2 class="text-lg font-bold text-base-content flex items-center gap-2">
              <.icon name="hero-code-bracket" class="size-5 text-primary" />
              <span>Open-Source-Software</span>
            </h2>
            <p class="text-sm text-base-content/80 mt-2 leading-relaxed">
              DealScout ist ein Open-Source-Projekt. Der Quellcode steht der Allgemeinheit unter einer freien Lizenz zur Verfügung.
              Es werden keine kommerziellen Absichten oder entgeltlichen Dienstleistungen über diese Webanwendung verfolgt.
            </p>
          </div>
        </div>

        <div class="text-center pt-2">
          <.link navigate={~p"/privacy"} class="btn btn-outline btn-sm gap-2">
            <.icon name="hero-shield-check" class="size-4" />
            <span>Zur Datenschutzerklärung</span>
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
