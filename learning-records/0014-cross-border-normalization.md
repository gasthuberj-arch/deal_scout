# Mastered Cross-Border Normalization and Regional Heuristics

Established patterns for domain-level origin detection, physical keyboard hardware categorization, and ingestion-time precomputation to protect users from incompatible cross-border imports.

## Evidence
- Completed Lesson 0011 interactive verification checkpoint covering domain origin heuristics, hardware taxonomy gating, and ingestion-time schema precomputation.

## Key Insights
- **Hardware Gating:** Physical compatibility warnings (e.g. AZERTY/QWERTY) must be gated by a hardware taxonomy check (`laptop`, `notebook`, `keyboard`) to avoid generating false warnings on universal electronics like monitors or headphones.
- **Affiliate Domain Masking:** Affiliate redirect URLs frequently obscure the real merchant domain; reliable origin detection requires combining host parsing with textual fallback markers in the title and description.
- **Ingestion Precomputation:** Multi-stage regex heuristics must run at write time during ingestion and persist onto the record, transforming expensive per-render regex cascades into zero-cost database column reads.
