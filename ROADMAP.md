# DealScout Feature Roadmap & Architecture Specifications

This document outlines the complete feature set, roadmap, and architectural designs for DealScout.

---

## 📋 Features Overview

### 1. 📊 Instant Idealo & Geizhals Price Comparison Links
- **How it works**: Automatically extract Geizhals (`geizhals.de/...`) and Idealo (`idealo.de/...`) URLs embedded in deal descriptions and affiliate redirects during feed ingestion.
- **UI**: 1-click comparison buttons rendered directly on each deal card:
  - `[📊 Idealo Price Chart]`
  - `[📈 Geizhals Price History]`
- **Value**: Instant access to 1-year historical price charts, price alerts, and 20,000+ merchant comparisons with zero scraping, no bot blocks, and $0 infrastructure cost.

### 2. 🔥 Deal Temperature & "Hot" Badges
- **How it works**:
  - Extract the community temperature score (e.g., `102°`) from Pepper feeds (MyDealz).
  - Strip the raw `102° - ` prefix from titles to keep clean typography.
  - Ingest the dedicated `https://www.mydealz.de/rss/trending` stream for pre-filtered community highlights.
- **UI**: Display temperature badges on cards (e.g., `🔥 102°` in fiery gradient / orange).
- **Alert Filter**: Add an optional threshold to user alert rules:
  - *“Only alert me if temperature ≥ 100°”* (strict filtering: ignores unrated deals).

### 3. 🛡 Merchant Guard, Safety Shield & Merchant Intelligence
- **How it works**:
  - **Dedicated Merchants Intelligence Table**: Normalized merchant records with `trust_level`, `deal_count`, `feed_counts` (per-deal-site breakdown), `avg_temperature`, and `last_seen_at`.
  - **Auto-Upsert & Intelligence Tracking**: Automatically create/update merchants during feed ingestion, tracking cross-portal frequency (MyDealz vs DealDoktor vs MonsterDealz).
  - **Smart Domain Extraction**: If an RSS post omits merchant tags, cleanly derive the merchant from the deal URL domain (e.g. `mediamarkt.de`), with fallback to *"Diverse Händler"*.
  - **Verified Whitelist (🟢)**: Reputable German and EU retailers (Amazon, Mindfactory, MediaMarkt, Saturn, Alternate, Cyberport, Otto, Lidl, Edeka, Galaxus, Coolblue, NBB, Kaufland, Decathlon).
  - **High-Risk / Scam Red Flags (🔴)**: Detect prepayment-only terms (*“nur Vorkasse”*, *“nur Überweisung”*), suspicious TLDs (`.top`, `.xyz`, `.buzz`), and grey-market key sellers.
  - **Spam Dropshipper Filter**: Identify marketplace dropshippers (Temu, AliExpress, Wish, Shein).
- **UI & Safety**:
  - Distinct safety status badges on cards (🟢 Verified, 🟡 Unverified, 🔴 High Risk).
  - **Merchant Intelligence Popover**: Hover/click merchant badge to see cross-portal deal frequencies (e.g. *“Seen 42 times across MyDealz (30), DealDoktor (12). Avg temp: 180° 🔥”*).
  - **1-Click Merchant Filtering**: Click merchant to filter the live stream by that merchant.
  - **Safety Interstitial Modal**: When clicking "Open Deal" on a high-risk shop, present a warning modal before redirecting (*“You are leaving DealScout to an unverified/flagged shop. Verify Impressum and pay with buyer protection.”*).
  - **Dropshipper Exclusions**: Checkbox on Alert Rules (default: exclude) and live feed toggle (*“Hide Dropshippers”*).

### 4. 🔗 Cross-Platform Deal Aggregation (De-Duplication)
- **How it works**:
  - Self-referential `canonical_deal_id` on the `deals` table. The earliest deal posted becomes the canonical parent; subsequent identical deals point to it.
  - Multi-factor matching engine (`DealScout.Deals.Deduplicator`):
    - Within a 24-hour sliding window.
    - Matches identical merchant AND (exact product URL / ASIN match OR title token similarity ≥ 80% + price within ±3%).
- **UI**:
  - Consolidated cards by default, with toolbar toggle (`Group Deals: ON/OFF`).
  - Consolidated deals render badges for alternate sources:
    - *Also posted on: [DealDoktor 16:45] [MonsterDealz 17:05]* with direct portal links.

### 5. 🇪🇺 Cross-Border EU Delivery Badges & Keyboard Warnings
- **How it works**:
  - `DealScout.Deals.CrossBorderGuard` classifies imported EU deals (Amazon FR, ES, IT, UK, etc.).
- **UI & Warnings**:
  - Country badges: 🇫🇷 Amazon FR, 🇪🇸 Amazon ES, 🇮🇹 Amazon IT, 🇬🇧 Amazon UK.
  - **Smart Keyboard Layout Warning**: If an imported deal is a laptop, keyboard, or notebook, display an amber warning banner:
    - *⚠️ Foreign Keyboard Layout (AZERTY / QWERTY likely, not DE-QWERTZ).*

### 6. 🌐 Expanded Community Sources
- **Ready-to-enable endpoints**:
  - **Preisjäger (Austria Pepper)**: `https://www.preisjaeger.at/rss` (DACH border deals).
  - **Dealabs (France Pepper)**: `https://www.dealabs.com/rss` (Amazon FR & Fnac hardware).
  - **Reddit Subreddits**: `r/bapcsaleseurope/.rss`, `r/GameDeals/.rss`.

### 7. 🦆 DuckDB Vectorized Analytics
- In-process analytical queries via DuckDB against `deal_scout.db`:
  - Historical lowest price records for any search term.
  - Speed-to-frontpage leaderboards (which portal publishes deals first).
  - Best days of the week / month to buy specific hardware categories.

---

## 🚀 Implementation Phases

| Phase | Features | Status |
|---|---|---|
| **Phase 1** | Idealo & Geizhals links (#1), Temperature badges (#2), Merchant Guard & Shield (#3) | In Progress |
| **Phase 2** | Merchant Intelligence & Cross-Portal Frequency Analytics | In Design |
| **Phase 3** | Cross-Border EU Badges (#5) & Expanded Feeds (#6) | Planned |
| **Phase 4** | Cross-Platform Aggregation / De-duplication (#4) | Planned |
| **Phase 5** | DuckDB Vectorized Analytics Engine (#7) | Planned |
