defmodule DealScout.Deals.MerchantGuardTest do
  use ExUnit.Case, async: true

  alias DealScout.Deals.MerchantGuard

  describe "classify/3" do
    test "classifies major German and EU retailers as verified" do
      assert MerchantGuard.classify("Amazon") == "verified"
      assert MerchantGuard.classify("amazon.de") == "verified"
      assert MerchantGuard.classify("MediaMarkt") == "verified"
      assert MerchantGuard.classify("Mindfactory") == "verified"
      assert MerchantGuard.classify("Alternate") == "verified"
      assert MerchantGuard.classify("Cyberport") == "verified"
      assert MerchantGuard.classify("Otto") == "verified"
      assert MerchantGuard.classify("Galaxus") == "verified"
      assert MerchantGuard.classify("Coolblue") == "verified"
      assert MerchantGuard.classify("Notebooksbilliger") == "verified"
      assert MerchantGuard.classify("Kaufland") == "verified"
    end

    test "classifies dropshippers as dropshipper" do
      assert MerchantGuard.classify("Temu") == "dropshipper"
      assert MerchantGuard.classify("AliExpress") == "dropshipper"
      assert MerchantGuard.classify("Wish") == "dropshipper"
      assert MerchantGuard.classify("Shein") == "dropshipper"

      assert MerchantGuard.classify("Random Shop", "https://aliexpress.com/item/123") ==
               "dropshipper"
    end

    test "classifies prepayment-only shops and suspicious TLDs as high_risk" do
      assert MerchantGuard.classify("GünstigShop", "https://guenstig-tv.top") == "high_risk"
      assert MerchantGuard.classify("BilligDeals", "https://deals.xyz") == "high_risk"

      assert MerchantGuard.classify(
               "Unbekannter Shop",
               "https://shop.de",
               "Zahlung: nur Vorkasse möglich"
             ) == "high_risk"

      assert MerchantGuard.classify(
               "TechStore",
               "https://techstore.com",
               "nur Überweisung akzeptiert"
             ) == "high_risk"

      assert MerchantGuard.classify(
               "Elektro Outlet",
               "https://outlet.de",
               "Achtung Fakeshop Warnung"
             ) == "high_risk"
    end

    test "classifies unknown shops without red flags as unverified" do
      assert MerchantGuard.classify("KleineBoutique24", "https://kleine-boutique.de") ==
               "unverified"

      assert MerchantGuard.classify("Uhrenlounge") == "unverified"
    end
  end

  describe "extract_domain/1" do
    test "extracts root domain from URLs and ignores aggregators" do
      assert MerchantGuard.extract_domain("https://www.mediamarkt.de/de/product/123.html") ==
               "mediamarkt.de"

      assert MerchantGuard.extract_domain("https://amazon.de/dp/B08N5WRWNW") == "amazon.de"
      assert MerchantGuard.extract_domain("https://www.mydealz.de/deals/sample-123") == nil
      assert MerchantGuard.extract_domain("https://dealdoktor.de/schnaeppchen/") == nil
    end
  end

  describe "slugify/1" do
    test "creates URL-friendly slugs with German umlaut normalization" do
      assert MerchantGuard.slugify("MediaMarkt") == "mediamarkt"
      assert MerchantGuard.slugify("ALDI Süd") == "aldi-sued"
      assert MerchantGuard.slugify("Kleine & Feine Händler") == "kleine-feine-haendler"
      assert MerchantGuard.slugify(nil) == "unknown"
      assert MerchantGuard.slugify("") == "unknown"
    end
  end
end
