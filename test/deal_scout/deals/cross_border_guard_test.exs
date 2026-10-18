defmodule DealScout.Deals.CrossBorderGuardTest do
  use ExUnit.Case, async: true

  alias DealScout.Deals.CrossBorderGuard

  describe "detect_country/1" do
    test "detects Amazon France" do
      res =
        CrossBorderGuard.detect_country(%{
          url: "https://www.amazon.fr/dp/B08N5WRWNW",
          title: "Casque Audio"
        })

      assert res == %{code: "FR", flag: "🇫🇷", name: "France"}
    end

    test "detects Dealabs as France" do
      res =
        CrossBorderGuard.detect_country(%{
          url: "https://www.dealabs.com/bons-plans/pc-portable",
          title: "Bon plan PC"
        })

      assert res == %{code: "FR", flag: "🇫🇷", name: "France"}
    end

    test "detects Amazon Spain" do
      res =
        CrossBorderGuard.detect_country(%{
          url: "https://www.amazon.es/dp/B08N5WRWNW",
          title: "Portátil"
        })

      assert res == %{code: "ES", flag: "🇪🇸", name: "Spain"}
    end

    test "detects Amazon Italy" do
      res =
        CrossBorderGuard.detect_country(%{
          url: "https://www.amazon.it/dp/B08N5WRWNW",
          title: "Portatile"
        })

      assert res == %{code: "IT", flag: "🇮🇹", name: "Italy"}
    end

    test "detects Amazon UK" do
      res =
        CrossBorderGuard.detect_country(%{
          url: "https://www.amazon.co.uk/dp/B08N5WRWNW",
          title: "Laptop deal"
        })

      assert res == %{code: "UK", flag: "🇬🇧", name: "UK"}
    end

    test "detects Preisjaeger Austria" do
      res =
        CrossBorderGuard.detect_country(%{
          url: "https://www.preisjaeger.at/deals/gaming-laptop-12345",
          title: "Laptop Angebot"
        })

      assert res == %{code: "AT", flag: "🇦🇹", name: "Austria"}
    end

    test "returns nil for standard German deals" do
      res =
        CrossBorderGuard.detect_country(%{
          url: "https://www.amazon.de/dp/B08N5WRWNW",
          title: "Laptop Angebot"
        })

      assert res == nil
    end
  end

  describe "keyboard_warning/1" do
    test "warns on laptop from France (AZERTY)" do
      warning =
        CrossBorderGuard.keyboard_warning(%{
          url: "https://www.amazon.fr/dp/B08N5WRWNW",
          title: "ASUS ZenBook 14 OLED Laptop",
          clean_text: "Top Notebook aus Frankreich"
        })

      assert warning != nil
      assert warning.layout == "AZERTY"
      assert warning.flag == "🇫🇷"
      assert warning.message =~ "AZERTY"
    end

    test "warns on gaming keyboard from Spain (QWERTY-ES)" do
      warning =
        CrossBorderGuard.keyboard_warning(%{
          url: "https://www.amazon.es/dp/B08N5WRWNW",
          title: "Logitech G Pro Gaming Tastatur",
          clean_text: "Mechanische Tastatur"
        })

      assert warning != nil
      assert warning.layout == "QWERTY-ES"
      assert warning.flag == "🇪🇸"
      assert warning.message =~ "QWERTY-ES"
    end

    test "warns on explicit AZERTY or ANSI keyword in text even without country" do
      warning =
        CrossBorderGuard.keyboard_warning(%{
          url: "https://www.mediamarkt.de/deal",
          title: "Keychron K2 Mechanische Tastatur (US-Layout)",
          clean_text: "Importmodell mit US-Layout"
        })

      assert warning != nil
      assert warning.message =~ "Non-German Keyboard Layout"
    end

    test "does NOT warn on non-keyboard electronics from France" do
      warning =
        CrossBorderGuard.keyboard_warning(%{
          url: "https://www.amazon.fr/dp/B08N5WRWNW",
          title: "Sony PlayStation 5 DualSense Controller",
          clean_text: "Wireless Gamepad"
        })

      assert warning == nil
    end

    test "does NOT warn on German laptops" do
      warning =
        CrossBorderGuard.keyboard_warning(%{
          url: "https://www.amazon.de/dp/B08N5WRWNW",
          title: "Lenovo ThinkPad E14 Laptop DE-QWERTZ",
          clean_text: "Deutsches Tastaturlayout"
        })

      assert warning == nil
    end
  end
end
