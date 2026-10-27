# Mastered Pathological Query Defense and Compute Guards

Established architectural strategies for defending high-throughput streaming systems from ReDoS, runaway AST evaluation, and CPU starvation via microsecond budget enforcement and circuit-breaker pausing.

## Evidence
- Completed Lesson 0010 interactive verification checkpoint covering ReDoS mechanics, AST bounding, and normalized microsecond auto-pause circuit breakers.

## Key Insights
- **ReDoS Prevention:** Nested quantifiers in user regexes produce exponential $O(2^n)$ backtracking states upon failure. Preventing this requires grammar-restricted AST parsing and Aho-Corasick linear scanning.
- **Normalized Duration Budgeting:** Microsecond execution times must be normalized across the number of batch items (`div(elapsed_us, deal_count)`) to prevent large legitimate batches from falsely tripping safety circuit breakers.
- **Stateful Auto-Pause:** When an alert exceeds its safety budget, auto-pausing updates persistence, evicts the rule from the compiled index in `:persistent_term`, and alerts the user without disrupting other concurrent matches.
