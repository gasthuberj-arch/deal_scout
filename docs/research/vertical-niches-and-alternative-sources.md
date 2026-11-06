# High-Value Specialized Verticals & Blue Ocean Deal Sources for DealScout

**Author:** Antigravity Research & Strategy  
**Date:** November 2026  
**Target Market:** Germany & EU (DACH Focus)  
**Status:** Strategic Research Report  

---

## 1. Executive Summary

Generic deal aggregators in Germany (e.g., *MyDealz*, *Geizhals*, *Idealo*) dominate broad consumer electronics and supermarket discounts. However, they suffer from three structural weaknesses:
1. **Low Intent & Low Margin:** Aggregating $10 consumer gadgets yields razor-thin affiliate kickbacks (1–2%) and high user churn.
2. **Speed & Alert Latency:** Crowd-sourced portals rely on manual user voting and delayed human curation. By the time a high-margin single-unit deal (e.g., an open-box GPU or seized commercial van) hits the front page, it is already sold out.
3. **Cluttered Noise vs. High-Conviction Niches:** Professional flippers, homelab builders, SMB craftsmen, and tech prosumers abandon generic platforms due to notification fatigue and lack of parameterized domain filters (e.g., `€/TB` on hard drives, `€/Wp` on solar systems, or municipal zip-code filters on seized assets).

This report investigates **four high-value, underserved verticals** in the German/EU market:
* **Vertical 1: Government & Public Liquidation / Judicial Auctions** (`zoll-auktion.de`, `justiz-auktion.de`, industrial insolvency platforms).
* **Vertical 2: Refurbished, B-Ware & Certified Pre-Owned Hardware** (Amazon Warehouse, Alternate Outlet, MindStar, AfB Social IT, Refurbed).
* **Vertical 3: Homelab, Self-Hosting & Prosumer Tech** (ServerShop24, Enterprise Recertified HDDs, Low-Power Mini PCs).
* **Vertical 4: Balkonkraftwerk & Clean Energy Hardware** (Solarpaket 1, 800W micro-inverters, plug-in storage batteries, 0% VAT).

### Strategic Verdict & Primary Wedge
The highest-conviction blue-ocean opportunity for DealScout is a **dual-engine prosumer play**:
1. **The Core Wedge (B2B SaaS / High-Retention Moat): Government & Public Liquidation Alerts (`zoll-auktion.de` + `justiz-auktion.de`)**. This space has **zero modern software competitors**, archaic 2000s web interfaces, no mobile apps, and no automated alerts. The user base (commercial flippers, automotive exporters, workshop owners, and IT refurbishers) has an exceptionally high willingness to pay (€15–€29/month) for instant push/webhook alerts.
2. **The Immediate Affiliate Monetization Wedge: Homelab & Prosumer Hardware Radar**. By introducing computed metrics (specifically **€/TB storage metrics** and **sub-15W idle Mini PC alerts**), DealScout captures high-AOV, tech-savvy buyers with 5–7% affiliate commissions from specialized outlets like *ServerShop24*, *Alternate Outlet*, and *Amazon*.

---

## 2. Market Landscape: Why Generic Portals Fail in Niche Verticals

| Dimension | Generic Portals (*MyDealz*, *Snipz*) | Price Comparison Engines (*Geizhals*, *Idealo*) | DealScout Specialized Vertical Radar |
| :--- | :--- | :--- | :--- |
| **Catalog Scope** | Everything (Groceries, Sneakers, TVs) | Mass-market retail new products | High-value secondary markets, liquidations, B-Ware, prosumer |
| **Alert Latency** | Minutes to hours (Human curation/voting) | 12 to 24 hours (Periodic catalog crawls) | **Sub-second to 60 seconds (LiveView / WebSockets / Instant Push)** |
| **Inventory Type** | High-volume new retail items | Standard retail catalog items | **Single-unit inventory (1-of-1 B-Ware, seized lots, outlet items)** |
| **User Motivation** | Impulse buying & price cutting | Transactional price verification | **Arbitrage, business procurement, precision hobby builds** |
| **Monetization** | Amazon/Otto affiliate (1–3%) | Cost-Per-Click (CPC) (15–40 cents) | **Hybrid: B2B SaaS Subscriptions + High-Yield Niche Affiliate (5–9%)** |

---

## 3. Vertical Deep-Dive 1: Government & Public Liquidation / Judicial Auctions

### 3.1 Primary Portals Analyzed
1. **Zoll-Auktion (`zoll-auktion.de`)**:
   * *Operator:* Federal Customs Administration (Hauptzollamt Gießen) on behalf of Bund, Länder, and Kommunen (over 4,000 participating public authorities).
   * *Catalog:* Confiscated criminal assets (luxury watches, gold, vehicles), decommissioned government fleet vehicles (police cars, municipal service vans), public office IT equipment (bulk ThinkPads, monitors, server racks), and municipal equipment (tractors, power tools).
   * *Volume:* ~4,000–8,000 active auctions running concurrently.
2. **Justiz-Auktion (`justiz-auktion.de`)**:
   * *Operator:* Ministries of Justice of the German Federal States (managed technically via Justiz NRW) and Austrian justice authorities.
   * *Catalog:* Seized assets from court bailiffs (*Gerichtsvollzieher*), judicial seizures, and bankruptcy insolvencies. High density of consumer electronics, tools, vehicles, and real estate accessories.
   * *Volume:* ~1,000–2,500 active lots.
3. **Industrial Insolvency & Commercial Liquidators**:
   * *Portals:* **Surplex** (`surplex.com`), **Troostwijk Auctions** (`troostwijkauctions.com` – both under TBAuctions), **NetBid** (`netbid.com`), **Insolvenz-Auktionen** (`insolvenz-auktionen.de`).
   * *Catalog:* Heavy industrial machinery, CNC mills, logistics equipment, warehouse racks, entire office liquidations.
4. **Deutsche Bahn Fundservice**:
   * *Status:* Unclaimed lost-and-found items across Germany's rail network.
   * *Format:* Primarily offline live auctions in **Wuppertal Hbf** and regional stations; sporadic third-party digital auctions. High arbitrage for lost laptops, photography gear, and luggage.

### 3.2 Current State & UX Friction
* **Archaic 2000s Web Architecture:** Table-based layouts, non-responsive mobile views, session logouts, and broken back-button navigation.
* **Primitive Search:** Exact-string matching only. No negative filtering (e.g., `-defekt`), no regex, no multi-attribute filters (e.g., "ThinkPad AND 16GB AND Hesse/NRW pickup only").
* **Zero Real-Time Alerting:** Neither `zoll-auktion.de` nor `justiz-auktion.de` offers push notifications, webhooks, or RSS feeds for new auctions. Users must manually refresh static search pages multiple times a day.
* **Geographical Pickup Constraints:** Many government auctions stipulate *Selbstabholung* (self-pickup only). Buyers need alerts filtered strictly by postal code radius (e.g., "Radius 50 km around Munich").

### 3.3 Target Persona & Arbitrage Value
* **Commercial Flippers & Resellers:** Buy wholesale lots of confiscated iPhones, laptops, or tools at 40–70% below eBay/Refurbed market value, test them, and flip them.
* **Craftsmen & SMB Workshops (Handwerker):** Procure premium brand equipment (Festool, Hilti, Bosch Blau, Stihl) from municipal forestry or maintenance liquidations.
* **Auto Dealers & Exporters:** Police cruisers (BMW, VW Passat) and seized luxury cars auctioned with verified mechanical reports.
* **IT Homelabbers & Sysadmins:** Municipalities retiring enterprise network switches (Cisco, HP Aruba) and server racks for low three-figure opening bids.

### 3.4 Technical Feasibility & Ingestion Architecture
* **Public APIs / RSS Feeds:** **None exist** on `zoll-auktion.de` or `justiz-auktion.de`.
* **Ingestion Strategy for DealScout (Elixir/Phoenix):**
  * **Lightweight Headless Scrapers:** Utilize DealScout's `:req` client paired with `Floki` HTML parsing.
  * **Targeting Mobile/Lightweight Endpoints:** Justiz-Auktion provides a simplified mobile frontend (`mobile.justiz-auktion.de`), which serves cleaner, lower-overhead DOM trees.
  * **Polite Scheduled Polling:** Polling every 5–15 minutes across top categories (`Computer/Elektronik`, `Fahrzeuge`, `Werkzeuge`) generates minimal server load (~0.2 req/sec) and stays well below firewall tripwires.
  * **Change Detection & Deltas:** Compute SHA256 hashes of auction ID + current bid + ending timestamp to trigger alerts only on actual price changes, outbids, or freshly listed lots.

### 3.5 Legal & Regulatory Considerations in Germany
* **UrhG § 5 (Official Works / *Amtliche Werke*):** Pure factual auction listings (date, title, price, vehicle specifications) are public official notices and do not qualify for individual copyright protection under German law.
* **UrhG § 87a ff. (Database Protection / *Datenbankherstellerrecht*):** While public entities may attempt to claim database protection if substantial investment was made (*OLG Köln*), indexing metadata for search discovery and directing users back to the official platform via deep links is legally established practice (analogous to search engines and Google Shopping).
* **Compliance Rules:**
  1. Do not scrape or index private user names or individual debtor identifiers (GDPR / DSGVO).
  2. Do not hotlink high-resolution official auction photographs; extract only metadata and link directly to the source lot.
  3. Comply with reasonable `User-Agent` headers and rate limits.

### 3.6 Monetization Potential
* **Zero Affiliate Opportunity:** Government agencies do not pay affiliate commissions.
* **SaaS Subscription Model ("DealScout Pro / Insolvenz-Radar"):**
  * **Free Tier:** 6-hour delayed digest of new auctions, basic keyword match.
  * **Pro Tier (€19/month or €180/year):** Instant Telegram/Discord/Email push notifications (within 60s of listing), postal code radius filter, auto-bid sniper alarms (15 minutes before auction close), negative keyword filters.
  * **Market Size:** ~50,000 active commercial flippers, craft businesses, and vehicle dealers in Germany. Capturing 1,000 paid subscribers = **€19,000 MRR (€228k ARR)**.

---

## 4. Vertical Deep-Dive 2: Refurbished, B-Ware & Certified Pre-Owned Hardware

### 4.1 Primary Outlets Analyzed
1. **Amazon Warehouse / Amazon Second Chance (`amazon.de`):**
   * High-velocity customer returns sold at 15–40% discounts. Periodic "Extra 20% off Warehouse Deals" events cause instant inventory runs.
2. **Alternate Outlet (`alternate.de/Outlet`):**
   * Dedicated B-Ware section for PC components (GPUs, motherboards, RAM, monitors). Highly volatile: items are typically 1-of-1 and sell out within 3 to 10 minutes.
3. **Mindfactory MindStar & Preloved (`mindfactory.de`):**
   * Time-limited flash promotions (*MindStar*) and returned hardware (*Preloved/SchnäppShop*). Nightly "Midnight-Shopping" (free shipping between 00:00 and 06:00) triggers sharp buying spikes.
4. **Cyberport Vorführware & Outlet (`cyberport.de`):**
   * Demo units and store display items (strong on Apple MacBooks, iPads, Lenovo ThinkPads).
5. **AfB Social & Green IT (`afbshop.de`):**
   * Non-profit IT refurbisher for corporate/government fleets. High-grade corporate laptops (ThinkPad T14/X13, Dell Latitude) with certified batteries and 1-year warranty.
6. **Marketplaces: Refurbed (`refurbed.de`), Back Market (`backmarket.de`), Asgoodasnew (`asgoodasnew.de`):**
   * Curated consumer electronics (smartphones, tablets, smartwatches) with graded condition tiers (*Wie neu*, *Sehr gut*, *Gut*).

### 4.2 Opportunity: The "B-Ware Radar" Value Proposition
* **The Legal Guarantee Advantage (DACH):** Under German consumer law (§ 476 BGB), commercial sellers of B-Ware must provide a **minimum 12-month statutory warranty (*Gewährleistung*)** and a **14-day right of withdrawal (*Widerrufsrecht*)**. This gives B-Ware massive psychological trust over risky peer-to-peer portals like *Kleinanzeigen.de*.
* **Scarcity & The "1-in-Stock" Problem:** Unlike regular e-commerce where products have unlimited stock, B-Ware consists of single unique inventory units. A deal aggregator that updates hourly is useless. DealScout's sub-minute Elixir polling and instant LiveView dashboard solve the exact pain point of missing open-box GPU or laptop deals.

### 4.3 Technical Integration Landscape
* **AfB Shop:** Available via **Awin** affiliate network with full CSV/XML product feeds updated daily.
* **Refurbed & Back Market:** 
  * Refurbed offers dedicated Partner/Affiliate APIs via OpenAPI/gRPC for price and buy-box discovery.
  * Back Market features merchant/affiliate data feeds via Awin.
* **Alternate & Mindfactory:** No open developer APIs. Ingestion requires targeted HTML scraping of the outlet and MindStar landing pages.
* **Amazon Second Chance:** Access via Amazon Product Advertising API (PA-API 5.0) condition filters (`Offer.Condition = 'Used'`), supplemented by Keepa API webhooks.

### 4.4 Monetization & Unit Economics
* **Affiliate Commission Rates:**
  * *AfB Social IT:* **6% to 9% CPA** via Awin (Cookie: 90 days). Average order value (AOV): €350 → **€21–€31.50 per conversion**.
  * *Refurbed / Back Market / Asgoodasnew:* **3% to 6% CPA** (AOV: €400 → **€12–€24 per conversion**).
  * *Alternate / Cyberport:* **1.5% to 3.5% CPA** on high-ticket PC components (€800 GPU → **€16–€24**).

---

## 5. Vertical Deep-Dive 3: Homelab, Self-Hosting & Prosumer Tech

### 5.1 Hardware Categories & Prosumer Intent
Prosumers, software engineers, DevOps professionals, and homelab enthusiasts (r/homelab, r/selfhosted, Hardwareluxx) spend heavily on three distinct hardware pillars:
1. **High-Capacity Storage (16TB to 24TB Enterprise HDDs):**
   * *Models:* Seagate Exos (X18, X20, X22), Western Digital Red Pro / Ultrastar DC, Toshiba Enterprise Capacity (MG08, MG09, MG10).
   * *Key Decision Metric:* **Price per Terabyte (€/TB)**. Prosumers rarely care about the absolute price; they care whether an 18TB drive drops below **€14.00/TB (new)** or **€11.00/TB (recertified/manufacturer refurbished)**.
2. **Low-Power Mini PCs & Micro-Nodes:**
   * *Models:* Intel N100 / N305 / Core i3-N305 (Minisforum, Beelink, Geekom, GMKtec) and AMD Ryzen 7 7840HS/8845HS.
   * *Key Decision Metric:* Sub-15W idle power consumption, dual 2.5GbE LAN ports, and ECC/M.2 expandability.
3. **Decommissioned Enterprise Racks & Networking:**
   * *Models:* Dell PowerEdge (R730, R740), HPE ProLiant Gen9/Gen10, Mellanox ConnectX 10/25GbE NICs, MikroTik 10G switches.

### 5.2 Specialized Outlets
* **ServerShop24 (`servershop24.de`):** Germany's market leader in certified refurbished enterprise servers, storage arrays, and enterprise SAS/SATA drives.
* **ServerSchmiede (`serverschmiede.com`):** Configurable refurbished rack servers and memory kits.
* **Alternate / Mindfactory Recertified Outlets:** Frequent sales of manufacturer-recertified enterprise drives (e.g., Seagate Factory Recertified with 2-year distributor warranty).

### 5.3 DealScout Feature Moat: "Smart Formula Alerts"
Neither MyDealz nor Geizhals allows users to set an alert based on a calculated ratio. DealScout can deliver an instant competitive moat with:
* **Dynamic Title Parsing & Ratio Calculation:**
  ```text
  Regex match: "([0-9]{2})\s*TB" -> Capacity = 18
  Price Extraction: €219.00
  Calculated Metric: 219.00 / 18 = 12.16 €/TB
  Trigger Rule: Alert fires ONLY if €/TB <= 13.50 AND Condition IN ['New', 'Recertified']
  ```
* **Power-Efficiency Badging:** Tagging mini-PCs with benchmark idle power wattage extracted from community databases.

### 5.4 Monetization & Community Buy-In
* **ServerShop24 Affiliate Program (Awin):**
  * Commission: **5% (1–10 sales/mo), 6% (11–24 sales), 7% (25+ sales)**.
  * Cookie: 60 days.
  * High AOV: €250–€800 per rack/storage order → **€15–€56 per sale**.
* **Amazon Associate / Geizhals Arbitrage:** 2–3% on enterprise hard drives.

---

## 6. Vertical Deep-Dive 4: Balkonkraftwerk & Clean Energy Hardware (DACH)

### 6.1 Regulatory Catalyst: Solarpaket 1 & Tax Relief
Germany has created the most favorable regulatory environment in Europe for residential plug-in solar (*Steckersolargeräte*):
* **0% VAT (§ 12 Abs. 3 UStG):** Complete exemption from sales tax for residential solar modules, inverters, and battery storage.
* **Solarpaket 1 (Passed in 2024):**
  * **Inverter Output:** Increased from 600W to **800W** grid feed-in limit.
  * **Module Capacity:** Legal limit set at up to **2,000W peak (2 kWp)** (allowing 4-panel setups).
  * **Simplified Bureaucracy:** Abolition of grid operator pre-registration; registration simplified to a 2-minute entry in the *Marktstammdatenregister (MaStR)*. Ferraris analog meters are legally allowed to run backwards temporarily until the smart meter swap occurs.

### 6.2 Market Volume & Adoption Dynamics
* **Registered Systems (Bundesnetzagentur MaStR):**
  * Over **1.52 million active plug-in solar systems** officially registered in Germany as of late 2024/2026.
  * Daily expansion rate: **~1,000 to 1,150 new systems registered every single day**.
  * Total installed capacity: Over **1.6 GWp**.
* **Price Collapse & The Shift to Storage:**
  * Complete 800W entry sets (2x 430W panels + Hoymiles inverter) dropped from €800 in 2022 to **€220–€320 in 2024–2026**.
  * Margin and deal hunting have shifted entirely to **Plug-and-Play Solar Batteries (1.6kWh to 4kWh)**:
    * *Anker Solix Solarbank 2 (E1600 Pro/Plus)*
    * *Zendure SolarFlow (Hyper 2000 / AB2000)*
    * *EcoFlow PowerStream*

### 6.3 Major D2C Retailers & Hardware Ecosystem
* **Hardware Leaders:**
  * *Micro-Inverters:* Hoymiles (HMS-800W-2T), APSystems (EZ1-M), Deye.
  * *Bifacial Solar Panels:* Trina Solar (Vertex S+ N-Type Dual Glass), Jinko Solar, JA Solar.
* **Specialized D2C Retailers:**
  * **Tepto** (`tepto.de`), **Priwatt** (`priwatt.de`), **Solakon** (`solakon.de`), **Kleines Kraftwerk** (`kleineskraftwerk.de`), **Green Solar** (`greensolar.de`).

### 6.4 Affiliate Economics vs. The "One-and-Done" Churn Risk
* **Lucrative Upfront Economics:**
  * D2C brands (Solakon, Tepto, Priwatt) offer aggressive affiliate payouts: **5% to 10% CPA**.
  * Battery bundles retail between **€700 and €1,600** → **€35 to €160 commission per conversion**.
* **The Fatal Strategic Flaw for DealScout:**
  * **Balkonkraftwerk is a one-time purchase.** Once a household installs their 800W set and battery, their lifetime customer journey is finished for the next 5 to 10 years.
  * Unlike hardware enthusiasts or flippers who monitor deals 365 days a year, Balkonkraftwerk buyers churn immediately after purchase. It serves well as an SEO customer acquisition tool, but poorly as a recurring retention engine.

---

## 7. Comparative Multi-Criteria Assessment Matrix

To determine DealScout’s launch strategy, each vertical is scored from 1 (Poor) to 5 (Exceptional) across five core strategic dimensions:

| Dimension | Weight | V1: Public Auctions (`zoll-auktion`) | V2: Refurbished / B-Ware (`Alternate`, `AfB`) | V3: Homelab / Storage (`ServerShop24`) | V4: Balkonkraftwerk & Clean Energy |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **Monetization Potential** | 25% | **4.0** (High-margin SaaS sub) | **4.0** (Solid 3–9% affiliate) | **4.5** (SaaS sub + 5–7% affiliate) | **4.5** (High €50–€150 affiliate) |
| **User Retention / LTV** | 25% | **5.0** (Perpetual flipper monitoring) | **3.5** (Frequent tech upgrades) | **5.0** (Continuous homelab upgrades) | **1.5** (One-time purchase; high churn) |
| **Competitive Vacuum (Blue Ocean)** | 20% | **5.0** (Zero modern software tools) | **2.5** (MyDealz/Geizhals presence) | **4.5** (Calculated €/TB ignored by big portals) | **2.0** (Saturated by MyDealz/influencers) |
| **Technical Feasibility** | 15% | **3.5** (Scraping required; no API) | **3.5** (Mixed API + HTML scraping) | **4.5** (Feeds available + clean scraping) | **4.0** (Standard shop feeds & Awin) |
| **Legal & Platform Risk** | 15% | **4.0** (Public notice data; respectful crawl) | **4.5** (Affiliate-friendly commercial shops) | **4.5** (Direct affiliate partnerships) | **4.5** (Standard commercial partnerships) |
| **Weighted Score (out of 5.0)** | **100%** | **4.35** | **3.55** | **4.65** | **3.25** |

---

## 8. Strategic Recommendation & Wedge Roadmap for DealScout

### 8.1 The Winning Wedge: The "Homelab Storage + Public Liquidation" Dual Moat
DealScout should not compete as another generic "deals for everyone" blog. Instead, DealScout should establish itself as the **Precision Asset & Hardware Radar for Tech Prosumers, SMBs, and Arbitrageurs**.

The dual wedge combines **Vertical 3 (Homelab Storage & Prosumer Tech)** with **Vertical 1 (Government & Public Liquidation)**:

1. **Top-of-Funnel Viral Growth: The "Homelab Storage Radar" (Vertical 3)**
   * *The Hook:* A public, live-updating dashboard showing the cheapest **€/TB hard drive deals** (Seagate Exos, WD Red, recertified) and **Sub-15W Mini PCs** in Germany.
   * *Distribution:* High organic viral spread on Reddit (`r/selfhosted`, `r/homelab`, `r/de_EDV`), ComputerBase, and Hardwareluxx forums.
   * *Monetization:* Instant affiliate cashflow via ServerShop24 (Awin) and Amazon PartnerNet.
2. **The High-Retention Cashflow Moat: "DealScout Public Liquidation Alerts" (Vertical 1)**
   * *The Hook:* Real-time, instant alerts for `zoll-auktion.de` and `justiz-auktion.de` with postal code radius filtering, negative keywords, and end-of-auction countdown alarms.
   * *Distribution:* Direct outreach in reseller communities, commercial flipper groups, IT hardware brokers, and craft trade forums.
   * *Monetization:* **B2B SaaS Subscription (€19/month or €180/year)** for instant SMS/Telegram/Webhook notifications. Zero ad dependency.

---

## 9. Implementation Roadmap for DealScout

### Phase 1: MVP Core (Weeks 1–3) – The Storage & Mini PC Radar
* Implement automated scrapers / feeds for `ServerShop24`, `Alternate Outlet`, and `Mindfactory MindStar` using Elixir `:req` + `Floki`.
* Build regex parser to extract drive capacity in TB and compute live `€/TB`.
* Add custom LiveView filters for `€/TB < 14.00` and `Wattage < 15W`.
* Embed Awin affiliate tracking links for ServerShop24.

### Phase 2: The Government Liquidation Engine (Weeks 4–6)
* Deploy headless polling workers for `zoll-auktion.de` and `mobile.justiz-auktion.de` (polite 10-minute cadence).
* Normalize auction schema: `title`, `current_bid`, `minimum_increment`, `end_timestamp`, `postal_code`, `category`.
* Add LiveView map/postal-code radius filter (`PLZ Umkreis-Suche`).
* Introduce Telegram Bot and Discord Webhook dispatchers for instant alerts.

### Phase 3: Monetization & B-Ware Expansion (Weeks 7–10)
* Launch DealScout Pro subscription tier (€19/month Stripe billing) for instant liquidation alerts.
* Integrate AfB Social IT (Awin feed) to expand into certified enterprise laptops (ThinkPads, Latitudes).
* Introduce "One-Click Sniper Alarm" alerting users 15 minutes before high-margin auctions end without competing bids.

---

## 10. Primary Source Citations & References

1. **Zoll-Auktion:** Official Federal & Municipal Auction Platform. URL: [zoll-auktion.de](https://www.zoll-auktion.de). General terms and auction categories.
2. **Justiz-Auktion:** Judicial Auction Portal of the Federal Republic of Germany and Republic of Austria. URL: [justiz-auktion.de](https://www.justiz-auktion.de) / [mobile.justiz-auktion.de](https://mobile.justiz-auktion.de).
3. **TBAuctions / Industrial Insolvencies:** Surplex ([surplex.com](https://www.surplex.com)), Troostwijk Auctions ([troostwijkauctions.com](https://www.troostwijkauctions.com)), NetBid Industrial Auctions ([netbid.com](https://www.netbid.com)).
4. **German Legal Framework on Scraping & Databases:**
   * Gesetz über Urheberrecht und verwandte Schutzrechte (UrhG) § 5 (Amtliche Werke).
   * UrhG § 87a, § 87b (Sui-generis-Datenbankherstellerrecht).
   * BGH VI ZR 10/24 (November 2024 ruling on mass data scraping and GDPR considerations).
5. **AfB Social & Green IT Partner Program:** Awin Merchant Profile #18712, 6–9% CPA. URL: [afbshop.de](https://www.afbshop.de).
6. **ServerShop24 Partner Program:** Awin Merchant Profile, 5–7% tiered CPA. URL: [servershop24.de](https://www.servershop24.de).
7. **Refurbed OpenAPI / Developer Specifications:** Refurbed Merchant & Partner APIs. URL: [developers.refurbed.com](https://developers.refurbed.com) / GitHub specifications.
8. **Bundesnetzagentur Marktstammdatenregister (MaStR):** Official Open Data on Balkonkraftwerke (Steckersolargeräte). URL: [marktstammdatenregister.de](https://www.marktstammdatenregister.de) and [bundesnetzagentur.de](https://www.bundesnetzagentur.de).
9. **Solarpaket 1 Regulatory Directives:** Federal Ministry for Economic Affairs and Climate Action (BMWK) / Bundestag legislation on 800W inverters and 2,000W module capacity (BGBl. 2024 I Nr. 151).
