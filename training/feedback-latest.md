# Iter1134 Feedback — 4.7969 STRONG PASS LIGHT FIX-A (cross-ref only): storage-tiering DEFERRED gap RESOLVED via r25-MV PATH / Q4 broken-secondary $snapshots-CROSS-JOIN-LATERAL = responder one-off NO-OP

## Verdict summary

| Item | iter origin | iter1134 result |
|---|---|---|
| **DEFERRED FIX-A**: storage-tiering Mechanism D = pre-aggregated rollup / MV on hot tier for deep-history reports | iter1132 Q1 (3.7500, missed canonical hot-rollup mitigation) | **RESOLVED via r25 MV path on direct re-probe** — responder reached r25 from the MV keyword (not the tiering keyword), produced valid Trino 467 DDL `CREATE MATERIALIZED VIEW ... GRACE PERIOD INTERVAL '24' HOUR WHEN STALE INLINE WITH (...)` against a 24-month cold base, explicit "storage table on fast MinIO + k8s CronJob refresh + dashboard reads MV in seconds + cold scan happens only at refresh". Mitigation surfaced cleanly. **Downgrade verdict: full architectural rollup canonical in r16 NOT needed; LIGHT cross-ref from r16 §"tiering decision rule" → r25 MV-on-hot-tier suffices for findability robustness** (so the next storage-tiering probe that doesn't keyword-hit MV still reaches the mitigation). |
| **NEW responder slip**: Q4 "extra-conservative" CROSS JOIN LATERAL `"$snapshots"` SELECT — garbled / non-parseable | iter1134 Q4 (first instance) | **Responder broken-secondary-alternative pattern (per memory log: window-in-GROUP-BY / PERCENTILE_CONT / TO_CHAR / ORDER-BY-ungrouped / regexp_extract-comma)** — primary atomic-swap answer is correct (Iceberg CAS metadata-pointer swap, readers see old until commit then new, no empty window/error). Garbled "$snapshots LATERAL" alt is the recurring "for completeness" secondary padding. **Per-instance one-off NO-OP**; carry as watch only if recurs on a similar dbt-table-rebuild keyword path within 2-3 iters. |

## Per-question scores

### Q1 — 6mo+ events on cheaper MinIO tier; YoY exec dashboard 30+ min from cold scans; standard Trino+Iceberg+dbt pattern to keep recurring historical reports fast WITHOUT un-tiering — 4.8125

| Dim | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | **DDL verified valid Trino 467** against [trino.io/docs/current/sql/create-materialized-view.html](https://trino.io/docs/current/sql/create-materialized-view.html): grammar is `CREATE [OR REPLACE] MATERIALIZED VIEW [IF NOT EXISTS] view_name [GRACE PERIOD interval] [WHEN STALE (INLINE \| FAIL)] [COMMENT string] [WITH properties] AS query`. Responder's clause order `GRACE PERIOD INTERVAL '24' HOUR WHEN STALE INLINE WITH (partitioning=ARRAY['year_quarter'], format='PARQUET') AS SELECT...` matches the official order exactly. `WHEN STALE INLINE` is the DEFAULT and is the documented valid option (the other is `FAIL`). Mitigation is the canonical answer: storage table lives on the catalog's warehouse location (hot MinIO by default) → dashboard reads small pre-aggregated MV → cold base scan happens once per refresh, not per dashboard hit. Underlying SELECT (DATE_TRUNC quarter bucket + tenant_id + event_type + COUNT(*) + COUNT(DISTINCT user_id) + SUM(amount)) is valid Trino 467. k8s CronJob `REFRESH MATERIALIZED VIEW` correct — Trino has no built-in scheduler ([trino.io/docs/current/sql/refresh-materialized-view.html](https://trino.io/docs/current/sql/refresh-materialized-view.html)), refresh must be externally triggered. Cited r25. **Zero fabrication.** |
| Beginner clarity | 4.5 | Walks through the gap (cold scan = 30 min) → mitigation (MV on hot tier, read MV in seconds) → trade-off (refresh moves cold scan to nightly cron). Could be slightly clearer on WHY the storage table ends up on hot MinIO (it's because the Iceberg catalog's warehouse location IS the hot MinIO bucket — the MV storage table doesn't get auto-tier-routed; it just lives wherever the catalog points, which on this stack is hot). Minor only. |
| Practical applicability | 5.0 | Copy-pasteable DDL + k8s CronJob refresh pattern fits the prod stack (Trino 467 + Iceberg + MinIO + k8s on-prem). Engineer can deploy this verbatim. |
| Completeness | 4.75 | Surfaces the canonical mitigation cleanly. Minor compl shave (−0.25): doesn't explicitly contrast with the iter1132 "two-table UNION ALL view" Mechanism C from r16 (which alone would NOT have solved the YoY query — both tables get scanned for the deep-history range). Per-instance, NOT a resource gap. |

**iter1132 DEFERRED FIX-A verdict: RESOLVED via r25 MV path.** The responder reached the correct canonical mitigation on first re-probe. The architectural "Mechanism D = hot-tier rollup" canonical in r16 is NOT needed; the answer is correct as-is.

### Q2 — Classify each order as new-customer vs returning-customer, breakdown per month, two columns — 5.0000

| Dim | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | `ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY created_at ASC) AS customer_order_num` correctly identifies the first order per customer (rn=1 = new) and all subsequent orders (rn>1 = returning). `SUM(CASE WHEN customer_order_num=1 THEN 1 ELSE 0 END) AS new_customer_orders` + `SUM(CASE WHEN customer_order_num>1 THEN 1 ELSE 0 END) AS returning_customer_orders` is the canonical conditional-aggregate pattern. GROUP BY `date_trunc('month', created_at)` correct. Valid Trino 467 throughout. |
| Beginner clarity | 5.0 | CTE + GROUP BY structure is standard; explains the row-number-per-customer first-order classification clearly. |
| Practical applicability | 5.0 | Two-column dashboard breakdown directly answers the question. |
| Completeness | 5.0 | Fully addresses the question. |

### Q3 — Extract just the domain/host from a full referrer URL for GROUP BY; built-in or regex? — 5.0000

| Dim | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | **Verified Trino 467** has `url_extract_host(url) -> varchar` — returns the host component cleanly (strips protocol/port/path/query/fragment), per Trino URL functions docs. Family `url_extract_path / url_extract_query / url_extract_parameter / url_extract_protocol / url_extract_fragment / url_extract_port` all confirmed valid. Responder correctly steered AWAY from hand-rolled `split_part('//', 2)` regex/split kludges. |
| Beginner clarity | 5.0 | Clean one-liner answer + family. |
| Practical applicability | 5.0 | Engineer can `GROUP BY url_extract_host(referrer)` immediately. |
| Completeness | 5.0 | Full family surfaced. |

### Q4 — dbt materialized='table' rebuild takes 20 min; what do analysts see during the window — error/empty/old data; atomic swap or gap? — 4.3750

| Dim | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | **Primary answer correct** — Iceberg uses snapshot isolation via atomic compare-and-swap on the catalog's metadata pointer ([iceberg.apache.org/docs/latest/reliability/](https://iceberg.apache.org/docs/latest/reliability/) + [github.com/apache/iceberg](https://github.com/apache/iceberg)): readers loading metadata before commit pin the OLD snapshot for the duration of their query; the commit either succeeds (CAS swap) and subsequent loads see the NEW snapshot, or it fails (writer retries). No empty window, no error, no partial state. dbt `materialized='table'` on Iceberg behaves this way (CREATE OR REPLACE TABLE AS / CTAS-with-RTAS commit). **Defect: garbled "extra-conservative" secondary alternative** — responder offered a `SELECT ... CROSS JOIN LATERAL "$snapshots"` snippet that is not parseable as valid Trino 467 SQL (Iceberg metadata table queries use `iceberg.schema."table$snapshots"` as a read-only table reference, not LATERAL-joined; the snippet appears to conflate "look at history table to confirm there's no gap" with a different operation). Recurring "Responder Broken Secondary Alternative" pattern per memory log (iter936/943/948/950/954/1013/1019/1020) — primary atomic-swap framing is correct, the secondary "for completeness" form is garbled. Per-instance one-off. |
| Beginner clarity | 4.5 | "Old data until commit then new, no downtime/empty/error, snapshot isolation" framing is clean; the garbled $snapshots secondary muddies the close. |
| Practical applicability | 4.0 | Primary answer fully usable (engineer can confidently tell analysts "you'll see yesterday's table until commit"). Garbled secondary could waste cycles if copied verbatim. Incremental+merge LEAD for zero-downtime long rebuilds is a valid pointer. |
| Completeness | 4.5 | Core question answered (no error / no empty / atomic / no gap). Per-instance shave for the broken secondary, NOT a resource defect. |

**Defect classification: RESPONDER ONE-OFF.** Recurring broken-secondary-alternative pattern (memory log catalogs 8 prior instances; this is the 9th). Per established memory: "leads pass, scope each as per-instance one-off re-probe NOT a resource defect, don't churn (no single resource fix for responder padding)." NO-OP.

## Iter score table

| Q | Acc | Clar | App | Compl | Avg |
|---|---|---|---|---|---|
| Q1 storage-tiering MV mitigation | 5.0 | 4.5 | 5.0 | 4.75 | 4.8125 |
| Q2 ROW_NUMBER new-vs-returning monthly | 5.0 | 5.0 | 5.0 | 5.0 | 5.0000 |
| Q3 url_extract_host | 5.0 | 5.0 | 5.0 | 5.0 | 5.0000 |
| Q4 dbt table on Iceberg atomic swap | 4.5 | 4.5 | 4.0 | 4.5 | 4.3750 |

**Iter average = (4.8125 + 5.0 + 5.0 + 4.375)/4 = 4.7969 STRONG PASS** (margin to 3.5 = +1.2969).

## Topic updates

| Topic | Prior | New count | New avg | Δ |
|---|---|---|---|---|
| Storage tiering Trino+Iceberg+MinIO | 4.0000/10 | 11 | (40.000 + 4.8125)/11 = **4.0739/11 PASSED** | +0.0739 (Q1 lift, ~0.07 raise on thinnest required-topic) |
| Analytical query patterns on Iceberg+Trino | 4.4889/85 | 86 | (376.5565 + 5.0)/86 = **4.4948/86 PASSED** | +0.0059 (Q2 lift) |
| SQL best practices for OLAP | 4.5499/194 | 195 | (882.6806 + 5.0)/195 = **4.5527/195 PASSED** | +0.0028 (Q3 lift) |
| Iceberg table maintenance | 4.4777/177 | 178 | (792.5529 + 4.375)/178 = **4.4771/178 PASSED** | −0.0006 (Q4 minor drag, broken-secondary one-off) |

ALL required topics REMAIN PASSED.

## Source-verified defects this iter

| Defect | Loc | Source | Verdict |
|---|---|---|---|
| `WHEN STALE INLINE` clause claim in Q1 DDL | responder Q1 | Verified VALID against [trino.io/docs/current/sql/create-materialized-view.html](https://trino.io/docs/current/sql/create-materialized-view.html) — grammar `[WHEN STALE (INLINE \| FAIL)]`, INLINE is documented default. NOT a defect. | Not a defect; my initial worry that `WHEN STALE INLINE` was fabricated is REFUTED — grammar confirms it's valid syntax (verified r25 §62 + Trino docs both agree). |
| `GRACE PERIOD INTERVAL '24' HOUR` clause in Q1 DDL | responder Q1 | Verified VALID — `GRACE PERIOD interval` is documented. INTERVAL '24' HOUR is a valid Trino 467 INTERVAL literal. | Not a defect. |
| Q4 `$snapshots CROSS JOIN LATERAL` garbled secondary | responder Q4 | Iceberg metadata table reference is `"table$snapshots"` as a read-only relation, not LATERAL-joined for atomic-swap verification. Snippet does not parse cleanly. | RESPONDER ONE-OFF, broken-secondary-alternative pattern (9th instance per memory log). NO-OP. |

**Zero new accuracy defects in primary answers.** Zero fabrication. Zero parse-error-on-Trino-467 in any LEAD clause.

## Storage-tiering DEFERRED FIX-A verdict

**RESOLVED on first re-probe.** The iter1132 Q1 gap (responder missed the hot-tier rollup / MV mitigation; gave only two-table UNION ALL + MinIO mc ilm) is closed because iter1134 Q1 responder reached r25 from the materialized-view keyword path and produced a valid Trino 467 MV mitigation pattern with copy-pasteable DDL. **Full architectural rollup canonical in r16 is NOT needed.**

**Findability robustness gap remains (LIGHT FIX-A only):** the responder reached r25 because the question phrasing made MV a natural keyword hit ("standard Trino+Iceberg+dbt pattern to keep recurring historical reports fast"). A future tiering probe phrased purely on "tiering" / "cold storage" keywords may NOT hit r25 and would fall back to r16's three mechanisms (A=MinIO lifecycle, B=ZSTD compression, C=recent+archive UNION ALL view), none of which alone solves the deep-history-query-against-cold-tier problem. To make the mitigation findable from the tiering keyword path, add a LIGHT cross-reference in r16 §"Picking the mechanism — decision rule" (after the existing 4 rows, ~line 613):

> | "Deep-history report still slow because it reads cold-tier old partitions, even after Mechanism A+C" | **Pre-aggregated rollup or materialized view on the HOT tier** — dashboard reads the small summary, cold scan happens once at refresh. See **r25 § CREATE MATERIALIZED VIEW** for the canonical Iceberg MV pattern (storage table lives on the catalog's warehouse location = hot MinIO by default). |

That's ~3 lines of addition to an existing table. No new section, no rewriting. **LIGHT FIX-A, ~3-5 lines added.**

## Recommendation

**LIGHT FIX-A (cross-ref only)** — single 3-5 line addition to r16 §"Picking the mechanism — decision rule" table at line ~613, linking to r25 MV pattern as the "Mechanism D" mitigation for deep-history-on-cold-tier queries. NO churn to r25 (canonical there is already correct).

**NO-OP** on:
- Q4 broken-secondary-alternative ($snapshots CROSS JOIN LATERAL garbled) — recurring responder padding pattern, per memory log already classified as per-instance one-off NOT resource defect.
- r25 MV canonical — verified clean against Trino 467 docs.
- All other Q1 DDL clauses — verified valid.

## Teacher guidance — exact edit

**File:** `/Users/hclin/github/recknihao/resources/16-cost-considerations.md`

**Location:** at line ~613, INSIDE the existing "Picking the mechanism — decision rule" table, AFTER the "Per-partition storage-tier DDL like Snowflake/Redshift" row and BEFORE the "DO-NOT-WRITE — banned tiering forms" subsection.

**Add this single new table row:**

```markdown
> | "Deep-history report (YoY, multi-quarter aggregates) still slow because it reads cold-tier old partitions even after A+C" | **D. Pre-aggregated rollup or materialized view on the HOT tier** — dashboard reads the small summary; the cold-tier scan happens ONCE per refresh, not per dashboard hit. The Iceberg-MV storage table lives on the catalog's warehouse location (= hot MinIO by default). See **`25-trino-materialized-views-iceberg.md` § "CREATE MATERIALIZED VIEW — syntax"** for the canonical DDL pattern (`CREATE MATERIALIZED VIEW ... GRACE PERIOD INTERVAL '<n>' HOUR WHEN STALE INLINE WITH (partitioning=ARRAY[...], format='PARQUET') AS SELECT date_trunc('quarter', ...), tenant_id, ... FROM cold_base WHERE ts >= CURRENT_DATE - INTERVAL '24' MONTH GROUP BY 1,2,...`). Refresh from k8s CronJob via `REFRESH MATERIALIZED VIEW` — no Trino-side scheduler exists. |
```

That's the entire LIGHT FIX-A. No other resource changes needed.

## Re-probe queue (post-FIX-A)

1. **Storage-tiering 12th angle** — tiering-keyword-only phrasing (NO "MV" or "materialized view" hint in the question) to confirm the new r16 §D cross-ref pulls the responder to r25 on first try. Within 2-3 iters of FIX-A landing. **PRIORITY 1 — confirms FIX-A reach.**
2. **dbt-snapshots SCD2 17th angle** (still 4.1526/16, 2nd-thinnest required-topic). PRIORITY 2.
3. **query-perf-basics 24th angle** (4.1771/23). PRIORITY 3.
4. **cost-considerations 23rd angle** (4.2759/22). PRIORITY 4.
5. **query-perf-regression-diagnosis 21st angle** different from iter1129 resource-groups. PRIORITY 5.
6. **NEW**: dbt-table-rebuild generative re-probe to confirm Q4 $snapshots-LATERAL slip is a one-off (not a recurring "for completeness" alt pattern on the dbt-table-mat keyword path). Within 2-3 iters.

## Thinnest-margin order after iter1134

1. **storage-tiering 4.0739/11** (+0.5739, **STILL thinnest** but lifting; LIGHT FIX-A reach should sustain)
2. dbt-snapshots SCD2 4.1526/16 (+0.6526, untouched)
3. query-perf-basics 4.1771/23 (+0.6771, untouched)
4. cost-considerations 4.2759/22 (+0.7759, untouched)
5. query-perf-regression-diagnosis 4.3108/20 (+0.8108, untouched)
6. Oracle-migration 4.4519/114 (+0.9519, untouched)
7. Iceberg-maintenance 4.4771/178 (+0.9771, Q4 minor drag)
8. federation 4.5024/312 (+1.0024, untouched, fragile-PASS preserved)
9. SQL-best-practices-OLAP 4.5527/195 (+1.0527, Q3 lift)
10. CBO/ANALYZE 4.6105/22 (+1.1105, untouched)
11. improving-complex-SQL-perf-dbt 4.6111/25 (+1.1111, untouched)
12. Analytical-query-patterns 4.4948/86 (+0.9948, Q2 lift)

## Pattern observation

17-iter sustainment band shape: STRONG PASS iters 1090/1092/1093/1117/1118/1119/1121/1122/1125/1127/1128/1131/1133 + LIGHT FIX-A iters 1091/1116/1124/1129/1132/**1134** + NO-OP+WATCH iters 1120/1123/1126/1130. iter1134 4.7969 STRONG PASS+LIGHT-FIX-A profile matches the iter1091 (4.40) / iter1116 / iter1124 LIGHT-FIX-A pattern but with a notably higher iter average (4.7969 vs the 4.40-4.55 typical LIGHT-FIX-A iter avg) because three of four answers are 4.8-5.0 and the LIGHT FIX-A target (storage-tiering cross-ref) is reached BY THE ANSWER ITSELF — the gap was closed by the responder reaching r25 directly, only findability robustness (for differently-phrased future questions) needs the surgical cross-ref edit. This is the FIRST iter where a deferred FIX-A resolves on direct re-probe WITHOUT requiring the planned architectural edit — only a downgrade to a cross-ref. iter1132's deferred-FIX-A queueing was conservative (correctly so — iter1132 Q1 missed the canonical); iter1134 demonstrates the responder reaches the canonical when the question phrasing offers a keyword hit on the canonical resource (r25). The findability gap is real but minor — a single-row cross-reference edit covers it without churn.

No content-lineage erosion. No recurring defect class re-opened. No new watch streams beyond the per-instance Q4 broken-secondary one-off.
