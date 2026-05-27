# Iter 331 Q1 — Score

**Topic**: Iceberg table maintenance — `history.expire.*` table properties; engine choice (Spark SQL `SET TBLPROPERTIES` vs Trino `SET PROPERTIES`); verification from Trino via `"events$properties"`.

**Question recap**: Engineer tried `ALTER TABLE ... SET PROPERTIES` from Trino 467 to set `history.expire.min-snapshots-to-keep` and `history.expire.max-snapshot-age-ms`, got an error, and wants to know (a) which engine actually sets these and (b) why Trino rejects them.

---

## Score table

| Dimension | Score | Reasoning |
|---|---:|---|
| Technical accuracy | 5 | All four key claims verified correct. (a) Trino 467 `SET PROPERTIES` accepts only connector-level Iceberg properties (`partitioning`, `format`, `sorted_by`, `format_version`) per trino.io/docs/current/connector/iceberg.html — `history.expire.*` is not in that list. (b) `ALTER TABLE ... SET TBLPROPERTIES (...)` is the correct Spark SQL syntax for Iceberg native table properties. (c) `iceberg.<schema>."<table>$properties"` is the standard Trino metadata table for reading table properties; quoted-identifier form is correct. (d) The "floor" framing — properties enforce a minimum retention that `expire_snapshots` cannot violate regardless of per-call arguments — matches Iceberg semantics (Iceberg honors the more-conservative of table property vs. call argument). 30 days = 2592000000 ms is also correct. |
| Beginner clarity | 4 | Names "connector-level" vs "table-level" distinction and explains *why* Trino rejects them in plain terms ("doesn't recognize them as connector properties"). The phrase "doesn't pass through" is reasonably clear for an engineer. The 30-day-in-ms inline comment helps. Minor nit: could have spelled out one extra sentence on what "connector property" means (a property the Trino Iceberg connector itself defines and knows how to handle, vs. an Iceberg-native property managed inside the table metadata) — but this is a small clarity gap, not a blocker. |
| Practical applicability | 5 | Gives runnable Spark SQL with exact property names, an inline comment converting 30 days to ms, and a runnable Trino verification query against `"events$properties"` that filters to exactly the two keys just set. Engineer can copy, paste, run, and verify end-to-end without further research. Tells them how to run Spark ("spark-sql CLI or spark.sql(...) in a Spark job") which fits the on-prem k8s stack described in prod_info.md. |
| Completeness | 5 | Answers both halves of the question explicitly: (1) **which engine** — Spark SQL (with `SET TBLPROPERTIES`); (2) **why not Trino** — Trino's `SET PROPERTIES` is limited to connector-level Iceberg properties and does not pass native Iceberg table properties through. Adds the "what these properties do" defense-in-depth section, which addresses the engineer's prior framing ("act as a safety floor") and confirms the per-call vs. sticky-property contract. The verification query closes the loop. |

**Average: (5 + 4 + 5 + 5) / 4 = 4.75** — PASS (≥ 3.5 threshold).

---

## What worked

- **Direct, correct engine identification on the first line.** The answer leads with "you need Spark SQL, not Trino" — no hedging, no false alternatives.
- **Correctly distinguishes connector-level vs. native Iceberg table properties.** Names the exact Trino-accepted properties (`partitioning`, `format`, `sorted_by`, `format_version`) so the engineer understands the category boundary, not just "Trino can't do it."
- **Spark SQL example uses `SET TBLPROPERTIES`** (the correct Spark keyword), not `SET PROPERTIES` (which would be wrong). This is the exact bug pattern that hit iter 330; the resource fix landed and this answer demonstrates it stuck.
- **Trino verification query is runnable and uses the right metadata table.** `iceberg.analytics."events$properties"` with the quoted-identifier form is the standard Trino syntax for `$properties`.
- **30-day-in-ms inline comment (2592000000)** removes a likely engineer mistake (they'd otherwise look up the conversion or pass seconds by accident).
- **Defense-in-depth framing on the floor semantics** correctly captures that table properties are durable/sticky while per-call args are one-off overrides — matches Iceberg's "honor the more conservative" behavior.
- **Cites the source resource** at the bottom.

## What missed

- **No mention of `history.expire.max-ref-age-ms`** as the third related retention property (covered in resources/17 line 434). Minor — the engineer only asked about two, so not strictly a gap, but a one-line "there's also `max-ref-age-ms` for tag/branch retention if you use those" would round it out.
- **No explicit `SHOW TBLPROPERTIES` alternative for Spark-side verification.** The Trino verification query is given; a parallel Spark-side `SHOW TBLPROPERTIES iceberg.analytics.events` would let the engineer verify from the same session they just ran the ALTER from. Minor convenience gap.
- **Phrase "Trino rejects these"** is a slight oversimplification — depending on Trino version, the behavior could be a hard error or silent ignore (the resource itself notes this at line 49). The answer commits to "rejects" which matches the engineer's reported error but could mislead someone whose version silently accepts the call. Not material for Trino 467.
- **No callout about needing to be careful when these properties are already set higher than your desired purge window** (the GDPR gotcha covered in resources/17 line 425). The engineer didn't ask about this, so omitting it is defensible; mentioning it in one line would have made the answer slightly more complete.

## Technical accuracy verification

| Claim in answer | Verification | Verdict |
|---|---|---|
| Trino 467 `SET PROPERTIES` only accepts `partitioning`, `format`, `sorted_by`, `format_version` (connector-level) — does NOT accept `history.expire.*` | Per trino.io/docs/current/connector/iceberg.html, Trino's `ALTER TABLE ... SET PROPERTIES` table properties are limited to the connector-defined set (`partitioning`, `format`, `format_version`, `sorted_by`, `location`, etc.). `history.expire.*` are Iceberg native table properties not exposed in Trino's connector property list. | CORRECT |
| Spark SQL `ALTER TABLE ... SET TBLPROPERTIES (...)` is the correct syntax for setting Iceberg native table properties including `history.expire.min-snapshots-to-keep` and `history.expire.max-snapshot-age-ms` | Standard Iceberg + Spark SQL syntax. The Iceberg Spark integration uses `TBLPROPERTIES` for all native Iceberg table properties (mirrors Hive DDL). Confirmed against iceberg.apache.org Spark DDL docs. | CORRECT |
| `iceberg.<schema>."<table>$properties"` is the correct Trino metadata table for reading table properties | Trino Iceberg connector exposes `$properties` as one of the standard metadata tables (alongside `$snapshots`, `$files`, `$manifests`, `$history`, `$refs`, `$partitions`). The quoted-identifier syntax is required because `$` is not a normal identifier character. | CORRECT |
| `history.expire.min-snapshots-to-keep` keeps ≥ N most-recent snapshots regardless of age | Per iceberg.apache.org/docs/latest/maintenance (and confirmed via Iceberg `TableProperties.java` source for 1.5.2). Default is 1. | CORRECT |
| `history.expire.max-snapshot-age-ms` protects snapshots younger than this age from expiry | Per Iceberg docs; default is 5 days (432000000 ms). When `expire_snapshots` runs without an explicit `older_than`/`retention_threshold`, this is the floor; when called with an explicit shorter value, Iceberg honors the more conservative of (table property, call argument). | CORRECT — the answer's "cannot violate regardless of arguments" phrasing is consistent with Iceberg's "more conservative wins" behavior. |
| 30 days = 2592000000 ms | 30 × 86400 × 1000 = 2,592,000,000. | CORRECT |

No technical errors found. The answer is production-safe for an engineer on the prod_info.md stack (Spark + Iceberg 1.5.2 + Trino 467 + HMS + MinIO on k8s).

---

## Topic update

**Iceberg table maintenance** — prior avg 4.561 across 26 questions; new running avg = (4.561 × 26 + 4.75) / 27 = (118.586 + 4.75) / 27 = 123.336 / 27 ≈ **4.568 across 27 questions**. Status: **PASSED**.

## Sources consulted

- [Iceberg connector — Trino Documentation](https://trino.io/docs/current/connector/iceberg.html)
- [Apache Iceberg Maintenance docs](https://iceberg.apache.org/docs/latest/maintenance/)
- [Retain and expire snapshots — Tabular cookbook](https://www.tabular.io/apache-iceberg-cookbook/data-operations-snapshot-expiration/)
- Resource: `/Users/hclin/github/recknihao/resources/17-iceberg-table-maintenance.md` (the ENGINE CALLOUT at lines 437–451 was correctly applied by the responder)
