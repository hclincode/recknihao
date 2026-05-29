# Iter 399 Feedback (EXTENDED PHASE — end-of-iteration only)

## Result: 4.0625 — PASS

- Q1 (concurrent INSERT + MERGE Iceberg): 4.0 PASS
- Q2 (SET SESSION vs catalog .properties): 4.125 PASS

---

## Pattern across both answers

The responder continues the consistent ~4.0–4.4 PASS band: correct core mechanism, production-stack-fit advice (on-prem Spark+Iceberg 1.5.2+HMS for Q1, Trino 467+OPA for Q2), one concrete actionable knob in each answer (`commit.retry.num-retries=4→8-12` for Q1, hyphen-vs-underscore gotcha for Q2). Both answers correctly identified the most important "what to do next" lever for an application engineer.

The recurring soft spot is **completeness on adjacent operational knobs** — Q1 named `commit.retry.num-retries` but didn't surface its three sibling backoff properties (`min-wait-ms`, `max-wait-ms`, `total-timeout-ms`) or the deeper `write.isolation-level` lever which is the real tuning knob for MERGE-vs-INSERT conflicts. Q2 named the hyphen/underscore gotcha but didn't surface the `catalog.property` prefix requirement that engineers will hit first when typing `SET SESSION` against a catalog property. Both gaps cost ~0.5 on Completeness without affecting Accuracy or Practical Applicability.

Beginner clarity dipped to 3.5 on Q1 because "optimistic concurrency," "atomically," and "CommitFailedException" were used without definition. A one-line plain-English gloss ("two writers race; whoever commits last sees the other already won and retries") would have lifted clarity to 4.5.

## Teacher actions next (iter 400)

1. **MEDIUM — Iceberg concurrent write resource expansion**: add the full retry-backoff property family (`commit.retry.min-wait-ms=100`, `commit.retry.max-wait-ms=60000`, `commit.retry.total-timeout-ms=1800000`) with an example timeline showing how 4 retries × exponential backoff fits inside the 30-minute total timeout. Add `write.isolation-level=serializable` vs `snapshot` explanation — this is the right knob for MERGE-vs-INSERT conflict severity in Iceberg 1.5.2, and the responder missed it.

2. **MEDIUM — MERGE conflict shape callout**: add a CoW-MERGE-vs-INSERT conflict-detection note: CoW MERGE rewrites files that an overlapping INSERT may also touch, producing a file-level snapshot conflict (not just a metadata-pointer race). This nuance matters for engineers asking specifically about INSERT + MERGE rather than INSERT + INSERT.

3. **LOW — Trino session property catalog-prefix callout**: add explicit one-liner that catalog session properties require `SET SESSION <catalog>.<property_name>=<value>` prefix syntax (e.g. `SET SESSION iceberg.target_split_size='128MB'`), not bare `SET SESSION target_split_size=...`. Add `SHOW SESSION` mention for discovering available session-tunable properties.

4. **LOW — Beginner-clarity layer for concurrency jargon**: add a one-line plain-English gloss for "optimistic concurrency control" (e.g. "no lock taken upfront; whoever commits first wins, others retry"). The responder uses the term frequently and a definition layer would lift beginner-clarity from 3.5 to 4.5 without extra length.

## Judge probe targets next (iter 400)

1. **`write.isolation-level` 2nd angle** — ask "MERGE keeps failing under concurrent INSERTs after raising retries to 12; what's the next knob?" to test whether responder reaches for isolation-level vs just more retries.
2. **`SHOW SESSION` / catalog-prefix syntax 2nd angle** — ask "how do I find which Iceberg properties are session-tunable" to probe `SHOW SESSION` knowledge and the catalog-prefix rule.
3. **Carry-forward backlog** (unchanged from iter 398): HMS→Nessie no-downtime, SPILL_FAILED 60GB at 200GB cap, MERGE INTO rollback, OPA-override timeout, schema registry compat, EXPLAIN TYPE IO + VALIDATE, result caching, Iceberg branches fast_forward, JWT+OPA concurrency, partition spec migration, Iceberg tagging 3rd angle, fs.cache 3rd angle JMX, `bucket(tenant_id)` very-high-cardinality 2nd angle, PERCENT_RANK/NTILE 3rd angle, RANGE INTERVAL gap-day semantics, partition spec evolution + `rewrite_data_files` migration.

## Topic score updates

- Iceberg table maintenance: 4.4779/56 → 4.4744/57 (Q1 4.0, PASSED)
- SQL query best practices for OLAP: 4.6373/20 → 4.6121/21 (Q2 4.125, PASSED)

## Verification notes

- `commit.retry.num-retries=4` default CONFIRMED via WebSearch (Cloudera + Iceberg KB).
- Trino SET SESSION hyphen→underscore CONFIRMED via WebSearch (Trino official docs + Iceberg connector docs).
- Both answers fit on-prem Trino 467 + Iceberg 1.5.2 + HMS + OPA stack per `prod_info.md`.
