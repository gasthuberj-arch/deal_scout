defmodule DealScoutWeb.LegalLive.Privacy do
  use DealScoutWeb, :live_view

  alias DealScout.Legal

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Datenschutzerklärung")
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
              <.icon name="hero-shield-check" class="size-6" />
            </span>
            <div>
              <h1 class="text-2xl sm:text-3xl font-extrabold tracking-tight">Datenschutzerklärung</h1>
              <p class="text-xs sm:text-sm text-base-content/70 mt-0.5">
                Informationen zur Verarbeitung personenbezogener Daten nach der DSGVO und dem TDDDG
              </p>
            </div>
          </div>
        </div>

        <%!-- Privacy-by-Design Highlights --%>
        <div
          id="privacy-by-design"
          class="alert alert-info border border-info/30 bg-info/10 text-base-content rounded-2xl"
        >
          <.icon name="hero-check-badge" class="size-6 text-info shrink-0" />
          <div class="text-xs sm:text-sm space-y-1">
            <h2 class="font-bold text-sm">Privatsphäre by Design</h2>
            <p>
              DealScout verzichtet bewusst auf Analyse-Tools, Werbe-Tracker (kein Google Analytics, kein Meta-Pixel) und externe Font-CDNs.
              Produktbilder werden über unseren eigenen Server gepuffert (<.link
                navigate={~p"/"}
                class="link link-hover font-mono"
              >/deals/:id/image</.link>),
              sodass Ihre IP-Adresse beim Durchstöbern von Deals nicht an externe Deal-Portale übertragen wird.
            </p>
          </div>
        </div>

        <%!-- 1. Verantwortliche Stelle --%>
        <div class="card bg-base-100 border border-base-300 p-6 sm:p-8 rounded-2xl shadow-sm space-y-3">
          <h2 class="text-lg font-bold text-base-content flex items-center gap-2">
            <.icon name="hero-user" class="size-5 text-primary" />
            <span>1. Verantwortliche Stelle</span>
          </h2>
          <div class="text-sm text-base-content/80 space-y-1">
            <p id="operator-name" class="font-semibold text-base-content">{@operator_name}</p>
            <p id="operator-address">{@operator_address}</p>
            <p class="pt-1">
              E-Mail:
              <a
                id="operator-email"
                href={"mailto:#{@operator_email}"}
                class="link link-primary font-mono text-xs sm:text-sm"
              >
                {@operator_email}
              </a>
            </p>
          </div>
        </div>

        <%!-- 2. Welche Daten verarbeitet werden --%>
        <div class="card bg-base-100 border border-base-300 p-6 sm:p-8 rounded-2xl shadow-sm space-y-6">
          <h2 class="text-lg font-bold text-base-content flex items-center gap-2">
            <.icon name="hero-document-text" class="size-5 text-primary" />
            <span>2. Verarbeitete Daten und Zwecke</span>
          </h2>

          <div class="space-y-4 text-sm text-base-content/80 leading-relaxed">
            <div class="space-y-1.5">
              <h3 class="font-bold text-base-content flex items-center gap-1.5">
                <span class="badge badge-primary badge-xs">A</span> Benutzerkonto &amp; Registrierung
              </h3>
              <p>
                Bei der Registrierung erheben wir Ihre <strong>E-Mail-Adresse</strong>
                und ein sicher gehashtes Passwort
                (unter Verwendung moderner kryptografischer Hashverfahren mit Salt). Die Speicherung dient der Authentifizierung,
                der Bereitstellung Ihrer persönlichen Alarme und der Zusendung von Bestätigungs- bzw. Login-E-Mails
                (Rechtsgrundlage: Art. 6 Abs. 1 lit. b DSGVO zur Durchführung des Nutzungsverhältnisses).
              </p>
            </div>

            <div class="space-y-1.5">
              <h3 class="font-bold text-base-content flex items-center gap-1.5">
                <span class="badge badge-primary badge-xs">B</span> Suchbegriffe &amp; Alarm-Regeln
              </h3>
              <p>
                Die von Ihnen hinterlegten Suchbegriffe, Negativ-Keywords, maximalen Preisgrenzen sowie die daraus resultierenden Treffer
                (Matched Deals) werden in der Datenbank gespeichert, um Deals in Echtzeit abzugleichen und in Ihrem Posteingang anzuzeigen
                (Rechtsgrundlage: Art. 6 Abs. 1 lit. b DSGVO).
              </p>
            </div>

            <div class="space-y-1.5">
              <h3 class="font-bold text-base-content flex items-center gap-1.5">
                <span class="badge badge-primary badge-xs">C</span>
                Web-Push-Benachrichtigungen (optional)
              </h3>
              <p>
                Wenn Sie Benachrichtigungen im Browser aktivieren, generiert Ihr Browser ein kryptografisches Schlüsselpaar und eine Endpunkt-URL
                des jeweiligen Push-Dienstes (z. B. Google Firebase Cloud Messaging, Apple Push Notification service oder Mozilla Push Service).
                Diese Schlüssel werden gespeichert, um Ihnen Deal-Benachrichtigungen zuzustellen (Rechtsgrundlage: Art. 6 Abs. 1 lit. a DSGVO / Einwilligung).
                Sie können Push-Benachrichtigungen jederzeit über die Browsereinstellungen oder in Ihren Profileinstellungen widerrufen.
              </p>
            </div>

            <div class="space-y-1.5">
              <h3 class="font-bold text-base-content flex items-center gap-1.5">
                <span class="badge badge-primary badge-xs">D</span> Server-Logdateien
              </h3>
              <p>
                Beim Aufruf der Webanwendung erfasst der Server technisch bedingt temporäre Zugriffsdaten (IP-Adresse, Datum und Uhrzeit der Anfrage,
                angeforderter Pfad, HTTP-Statuscode). Die Erfassung erfolgt zur Gewährleistung der Stabilität, Sicherheit und Fehlerbehebung
                (Rechtsgrundlage: Art. 6 Abs. 1 lit. f DSGVO / berechtigtes Interesse).
              </p>
            </div>
          </div>
        </div>

        <%!-- 3. Cookies & TDDDG --%>
        <div class="card bg-base-100 border border-base-300 p-6 sm:p-8 rounded-2xl shadow-sm space-y-3">
          <h2 class="text-lg font-bold text-base-content flex items-center gap-2">
            <.icon name="hero-circle-stack" class="size-5 text-primary" />
            <span>3. Cookies &amp; Lokaler Speicher</span>
          </h2>
          <p class="text-sm text-base-content/80 leading-relaxed">
            DealScout setzt <strong>ausschließlich technisch notwendige Cookies</strong>
            ein (z. B. Session-Cookies und das optionale
            Remember-Me-Cookie
            <code class="text-xs bg-base-200 px-1.5 py-0.5 rounded font-mono">_deal_scout_web_user_remember_me</code>
            zur dauerhaften Anmeldung).
            Diese Cookies sind zwingend erforderlich, um den gewünschten Dienst bereitzustellen (§ 25 Abs. 2 Nr. 2 TDDDG).
            Es werden <strong>keine</strong>
            Tracking-, Werbe- oder Marketing-Cookies verwendet.
          </p>
        </div>

        <%!-- 4. Speicherdauer & Kaskadierende Löschung --%>
        <div class="card bg-base-100 border border-base-300 p-6 sm:p-8 rounded-2xl shadow-sm space-y-3">
          <h2 class="text-lg font-bold text-base-content flex items-center gap-2">
            <.icon name="hero-clock" class="size-5 text-primary" />
            <span>4. Speicherdauer &amp; Datenlöschung</span>
          </h2>
          <ul class="list-disc list-inside text-sm text-base-content/80 space-y-1.5 leading-relaxed">
            <li>
              <strong>Deal-Daten:</strong>
              Eingelesene Deals werden nach 30 Tagen automatisch durch einen internen Bereinigungsprozess aus der Datenbank entfernt.
            </li>
            <li>
              <strong>Benutzerdaten:</strong>
              Daten Ihres Benutzerkontos werden gespeichert, solange Ihr Konto aktiv ist.
              Bei Löschung Ihres Kontos werden alle zugeordneten Alert-Regeln, Treffer und Push-Registrierungen sofort kaskadierend aus der Datenbank gelöscht.
            </li>
          </ul>
        </div>

        <%!-- 5. Ihre Rechte --%>
        <div class="card bg-base-100 border border-base-300 p-6 sm:p-8 rounded-2xl shadow-sm space-y-3">
          <h2 class="text-lg font-bold text-base-content flex items-center gap-2">
            <.icon name="hero-shield-exclamation" class="size-5 text-primary" />
            <span>5. Ihre Rechte als betroffene Person</span>
          </h2>
          <p class="text-sm text-base-content/80 leading-relaxed">
            Sie haben nach der DSGVO jederzeit das Recht auf unentgeltliche <strong>Auskunft</strong>
            über Ihre gespeicherten personenbezogenen Daten (Art. 15 DSGVO),
            deren <strong>Berichtigung</strong>
            (Art. 16 DSGVO), <strong>Löschung</strong>
            (Art. 17 DSGVO), <strong>Einschränkung der Verarbeitung</strong>
            (Art. 18 DSGVO)
            sowie auf <strong>Datenübertragbarkeit</strong>
            (Art. 20 DSGVO).
          </p>
          <p class="text-sm text-base-content/80 leading-relaxed pt-1">
            Wenden Sie sich zur Wahrnehmung Ihrer Rechte einfach per E-Mail an:
            <a
              href={"mailto:#{@operator_email}"}
              class="link link-primary font-mono text-xs sm:text-sm"
            >
              {@operator_email}
            </a>
          </p>
        </div>

        <div class="text-center pt-2">
          <.link navigate={~p"/impressum"} class="btn btn-outline btn-sm gap-2">
            <.icon name="hero-scale" class="size-4" />
            <span>Zum Impressum</span>
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
