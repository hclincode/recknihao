# Judge Feedback — Iteration 1310

**Phase**: extended (pass-loop)
**Overall iteration score**: **3.8125 PASS (overall avg ≥ 3.5)** but TWO QUESTION-LEVEL FAILS (Q1 2.875 / Q2 2.625 / Q3 4.875 / Q4 4.875).

**Pattern**: a single iteration with **two related-shape FAILs** on Q1 + Q2 — both questions ask a precise side-question (Q1 "does output format differ", Q2 "BEFORE running"), and on both the responder gave a mechanism-rich answer that addresses the *adjacent* question while getting the *literal asked* sub-question wrong. Q3 + Q4 pin-perfect.

- **Q1**: Mechanism (md5 / to_utf8 / to_hex / concat_ws / VARCHAR storage) is fully correct, BUT the "does output format differ from Postgres" answer is **WRONG and internally self-contradictory**: responder gave a lowercase example digest `'5d41402abc...'` and in the same paragraph asserted "BOTH ARE UPPERCASE hex strings." The case **DOES** differ (Postgres `md5(text)` returns LOWERCASE hex; Trino `to_hex(md5(...))` returns UPPERCASE hex), and the fix to match Postgres exactly is `lower(to_hex(md5(...)))`. This is the exact thing the engineer asked.
- **Q2**: Engineer explicitly asked for a way to see scan size **BEFORE running** (ahead-of-time). Responder routed to `EXPLAIN ANALYZE`, which **executes** the query — i.e. it re-runs the 40-second query the engineer is complaining about. The correct pre-run tools are plain `EXPLAIN` (TYPE DISTRIBUTED) and especially `EXPLAIN (TYPE IO, FORMAT JSON)` (no execution; surfaces planner row/byte estimates + `constraints` per input table — exactly the "did partition pruning fire" diagnostic the engineer wants).
- **Q3**: Pin-perfect (compile-time relation resolution + DAG dependency + env portability + source() for raw; final SQL identical to Trino).
- **Q4**: Pin-perfect (no ROWID in Trino; `ROW_NUMBER() OVER (PARTITION BY)` + `WHERE rn=1`; no `QUALIFY` in 467; CTAS/MERGE for in-place dedup).

---

## Per-question scoring

### Q1 — Postgres md5 surrogate key → Trino equivalent + format parity — **2.875 FAIL**

Acc 2.5 / Clar 3.5 / Prac 2.5 / Compl 3.0.

**Setup**: hash `tenant_id||email||signup_ts` as a stable surrogate key on Iceberg; Postgres `md5(text) -> text`. What's the Trino equivalent? Column type? Does the output FORMAT differ from Postgres?

**Responder**: Trino `md5()` takes/returns `VARBINARY`; full pattern `to_hex(md5(to_utf8(concat_ws('||', CAST(tenant_id AS VARCHAR), CAST(email AS VARCHAR), CAST(signup_timestamp AS VARCHAR)))))`. `concat_ws` delimiter prevents collision; `to_utf8` string→bytes (hash fns accept varbinary only); `to_hex` binary→hex (32 chars md5). Store as `VARCHAR`. Then on format: "if Postgres `md5()` produces `'5d41402abc...'`, Trino `to_hex(md5(...))` produces THE SAME FORMAT — BOTH ARE UPPERCASE hex strings." Also mentioned `dbt_utils.generate_surrogate_key` as the dbt-trino canonical.

**What is right**: mechanism (varbinary signature, `to_utf8` for string→bytes, `to_hex` for printable hex, `concat_ws` delimiter to avoid `'ab' + 'cd' == 'a' + 'bcd'` collisions, `VARCHAR` storage column type, `dbt_utils.generate_surrogate_key` as the dbt canonical) — all correct and findable in r23 §1162-1180 + r27 §4.5A.

**What is wrong (the asked question)**: the format-parity claim is BOTH factually wrong AND self-contradictory:
- **Factually wrong**: Postgres `md5(text) -> text` returns a 32-char **LOWERCASE** hex string. Trino `to_hex(...)` returns **UPPERCASE** hex. So they do NOT match in format — the case differs.
- **Self-contradictory inside the same answer**: the responder's own illustrative digest `'5d41402abc...'` is written in lowercase, and the next sentence asserts "BOTH ARE UPPERCASE."
- **Missing the actionable fix**: to make Trino emit the same string as Postgres (so joins / lookups against legacy Postgres-keyed tables work), wrap with `lower(...)`: `lower(to_hex(md5(to_utf8(concat_ws('||', CAST(...) AS VARCHAR, ...)))))`. Without this wrapper, a key migrated from Postgres `md5('alice@x.com')` = `7b6f...` will NOT equal Trino `to_hex(md5(to_utf8('alice@x.com')))` = `7B6F...` and any join/lookup against legacy keys silently produces zero rows — a hard-to-diagnose silent breakage.

**VERIFIED**:
- Postgres `md5(text)` returns lowercase hex — confirmed via [PostgreSQL MD5() Function (Neon)](https://neon.com/postgresql/postgresql-string-functions/postgresql-md5) example `'902fbdd2b1df0c4f70b4a5d23525e932'` (lowercase digits a-f) and consistent across [GeeksforGeeks PostgreSQL md5](https://www.geeksforgeeks.org/postgresql-md5-function/), [SQLiz PostgreSQL md5](https://www.sqliz.com/postgresql-ref/md5/).
- Trino `to_hex(varbinary)` returns **uppercase** hex — confirmed by git-tag-source WebFetch of [trinodb/trino@467 VarbinaryFunctions.java](https://github.com/trinodb/trino/blob/467/core/trino-main/src/main/java/io/trino/operator/scalar/VarbinaryFunctions.java) — the implementation uses the literal byte array `UPPERCASE_HEX_DIGITS = {'0','1',...,'9','A','B','C','D','E','F'}` so the returned string is uppercase A-F. Independently confirmed by [trino.io/docs/467/functions/binary.html](https://trino.io/docs/467/functions/binary.html) (signature `to_hex(binary) -> varchar`).

**Resource-sourced or responder slip?** **Hybrid — primarily a responder slip with a resource emphasis gap.**
- r23 §1162-1180 (the LEADING CANONICAL — hash/anonymize a string column) **correctly** says `to_hex(md5(to_utf8(email)))` produces a "32-char **uppercase** hex VARCHAR" — that's right for Trino.
- r27 §4.5A (the surrogate-key canonical) describes the output as "VARCHAR MD5 hex string, ~32 chars" — true but does not specify case.
- Neither r23 §1162-1180 nor r27 §4.5A explicitly contrasts the **case difference between Postgres md5 (lowercase) and Trino to_hex (uppercase)**, nor surfaces the `lower(to_hex(md5(...)))` parity wrapper. So the responder had no anchor to lift from when the engineer specifically asked about Postgres parity — and gravitated to a false "both uppercase" answer that contradicts even its own example.

**Recommended FIX-A (LIGHT, additive)**: at r23 §1162-1180 (and a back-cross-ref at r27 §4.5A surrogate-key) add a short Postgres-parity callout — e.g.:

> **Postgres parity gotcha — case differs.** Postgres `md5(text)` returns LOWERCASE hex (`'5d41402a...'`); Trino `to_hex(md5(to_utf8(...)))` returns UPPERCASE hex (`'5D41402A...'`). If you are joining/lookup against pre-existing Postgres-md5 keys, **wrap with `lower(...)`** so the strings match exactly: `lower(to_hex(md5(to_utf8(concat_ws('||', CAST(a AS VARCHAR), ...)))))`. Without this wrapper a key migrated from Postgres `md5(...)` will not `=` its Trino counterpart and joins silently return zero rows.

This is 1st-occurrence so a LIGHT additive callout is warranted (the engineer explicitly asked the format-parity question, and the case-difference is a silent-breakage class — not just academic).

**Classification**: responder slip (the resource has the Trino-side case right; nobody asserted "both uppercase" in resources) AMPLIFIED by a resource emphasis gap (no Postgres-parity callout exists). Self-contradictory output ("lowercase example, uppercase claim" in same paragraph) is the standard Haiku synthesis ceiling on parity questions.

No imported-prior, no broken-secondary, no over-warning, no fabrication (just the wrong literal claim on the asked side-question).

### Q2 — Estimate scan size BEFORE running a slow COUNT — **2.625 FAIL**

Acc 2.5 / Clar 3.5 / Prac 2.0 / Compl 2.5.

**Setup**: `SELECT COUNT(*) FROM events WHERE status='failed' AND occurred_at BETWEEN ...` for a week takes 40+ seconds despite being a "small subset." Engineer wants a way to see **AHEAD OF TIME / BEFORE running** how much Trino will scan, to tell if it's reading the whole table.

**Responder**: "Use `EXPLAIN ANALYZE` — runs the query, shows actual bytes read." Walked through reading `TableScan` `physicalInputDataSize` (bytes from MinIO before filtering); if huge = partition pruning failed (function/cast on partition col defeats pruning).

**What is right (diagnostically)**: the `physicalInputDataSize` field IS the actual-bytes-from-MinIO metric on the `TableScan` operator. The partition-pruning interpretation (huge bytes scanned vs. tiny expected partition range = pruning broke) is correct as a runtime diagnostic. So if the engineer DOES run EXPLAIN ANALYZE, they will get correct information.

**What is wrong (the asked question)**: the engineer's literal question is **BEFORE running** / **ahead of time**. `EXPLAIN ANALYZE` **executes the query** — i.e. running it costs the full 40 seconds the engineer was already paying. It is the wrong variant for the question as asked.
- **The correct pre-execution tools are**:
  - **Plain `EXPLAIN <query>`** (default `TYPE DISTRIBUTED`) — does NOT run the query; shows the planner's estimated rows/CPU/memory and the `TableScan` with the `constraint = ...` annotation indicating which predicates were pushed down vs. left as a residual `Filter` above the scan.
  - **`EXPLAIN (TYPE IO, FORMAT JSON) <query>`** — does NOT run the query; returns JSON with `inputTableColumnInfos` showing the `columnConstraints` (which predicates pushed down to the connector) and the planner's `estimate` (row count + size) **the scan WILL read** per input table. This is exactly the "did partition pruning happen at the scan boundary, and how many bytes will I read" pre-execution view the engineer is asking for.
  - `EXPLAIN ANALYZE` is for AFTER-run confirmation of actual bytes/rows, not pre-execution estimation.
- **Also missing the most likely cause**: `status = 'failed'` is almost certainly a **non-partition column** (the partition is `occurred_at` / day). Even with perfect partition pruning on the week-window, Trino still scans every data file in those 7 partitions and applies `status='failed'` at read. If `failed` is a rare value (a few % of rows), that scan reads the full ~7-day file footprint even if only a fraction of rows match — and that's why "small result set" doesn't mean "small scan." The responder's framing ("partition pruning failed due to function/cast on partition col") describes a different — and less likely — root cause given the query as written: there's no function on `occurred_at` in the engineer's snippet, only on `status`. The likely answer is: **the partition prune is fine; you're reading 7 day-partitions because that's the right partition window for the date range, then materializing `status='failed'` per row** — perfectly normal Iceberg behavior, and the fix is either (a) sorted_by/clustering on `status` to enable row-group skipping, (b) Parquet bloom filter on `status` (467 CREATE TABLE WITH property, see pinned `reference_trino_parquet_bloom_filter_469`), or (c) accept that "small result" does not mean "small scan" on an analytics table.

**VERIFIED**:
- Plain `EXPLAIN` does not execute, gives estimates from table stats — confirmed via WebFetch of [trino.io/docs/467/sql/explain.html](https://trino.io/docs/467/sql/explain.html) (responses: "EXPLAIN (without ANALYZE) does **not execute the query**. It shows the execution plan that would be used if the query ran.").
- `EXPLAIN (TYPE IO)` also does not execute; surfaces `inputTableColumnInfos` constraints + estimates — confirmed via the same WebFetch ("provides metadata about which tables and columns would be accessed, along with constraint information and estimates — all determined statically without running the actual query").
- `EXPLAIN ANALYZE` does execute — confirmed via WebFetch of [trino.io/docs/467/sql/explain-analyze.html](https://trino.io/docs/467/sql/explain-analyze.html) (and via [Medium: Query Plans — Trino](https://medium.com/@simon.thelin90/query-plans-analyse-sql-performance-in-trino-97ac1e8f8044)).

**Resource-sourced or responder slip?** **Resource emphasis pattern + responder findability slip.**
- r23 §2487-2496 ("EXPLAIN variants — which one surfaces which signal") has a clean table that explicitly states `EXPLAIN` and `EXPLAIN (TYPE IO)` do NOT run the query, and `EXPLAIN ANALYZE` DOES. The information IS present.
- r18 §"When to use each in practice" (lines 833-841) has a LEADING CANONICAL block: "When an engineer asks 'did my WHERE predicate push down to the Iceberg connector without me running the query?', the answer is: run `EXPLAIN (TYPE IO, FORMAT JSON)` ... TYPE IO is **cheap** (no scan, no execution — just the CBO walking the plan) and is the right first step before reaching for `EXPLAIN ANALYZE`."
- However, BOTH resources spend significantly more text on `EXPLAIN ANALYZE` diagnostics (operator fields, `Physical Input`, `Filtered:%`, the 5-row red-flag cheat-sheet) than on the plain `EXPLAIN` / `EXPLAIN (TYPE IO)` pre-execution use case. So the resource has the right answer but the keyword-gravity tilts toward EXPLAIN ANALYZE — Haiku reaches for the most prominent EXPLAIN canonical and ignores the variant distinction even when the engineer's literal phrasing ("BEFORE running", "AHEAD OF TIME") is the routing signal.

**Recommended FIX-A (LIGHT, additive — keyword-magnet block)**: add a short keyword-anchored leading canonical near the EXPLAIN-variant table in r23 §2487 AND/OR r18 §831 explicitly catching the pre-run phrasings:

> **READ FIRST when an engineer asks "BEFORE running" / "ahead of time" / "without running the query" / "estimate the scan size" / "will Trino read the whole table" / "dry run" / "preview the scan":** reach for **plain `EXPLAIN`** or **`EXPLAIN (TYPE IO, FORMAT JSON)`** — NOT `EXPLAIN ANALYZE`. `EXPLAIN ANALYZE` **executes the query** (it's the AFTER-run confirmation tool); the engineer asking "before running" wants the cheap planner pass that does NOT touch data. The `inputTableColumnInfos[].estimate` field in `EXPLAIN (TYPE IO, FORMAT JSON)` gives the planner's predicted `rows` and `size` per input table — that's the "how much will Trino scan" pre-execution view.

This is the first explicit "before-running" keyword miss I've seen this sweep but the recurring pattern (responder reaches for EXPLAIN ANALYZE on every EXPLAIN-flavored question) suggests adding the routing block now would prevent the next recurrence. The fix is purely additive — adds a routing card without contradicting the existing material — so low over-attraction risk per `feedback_new_card_over_attracts_adjacent.md`.

**Classification**: responder findability slip on a literal keyword cue ("BEFORE running" / "ahead of time"), amplified by resource emphasis weight toward `EXPLAIN ANALYZE`. No imported-prior, no broken-secondary, no over-warning, no fabrication.

### Q3 — dbt `ref()` vs hardcoded `schema.table` — **4.875 STRONG PASS**

Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 4.75.

**Setup**: staging → marts in the dbt+Trino stack. People keep saying "use `ref()` not `FROM schema.table`." What does `ref()` do differently, and does it matter for Trino execution?

**Responder**: `ref()` resolves at compile time to the actual relation (qualified `catalog.schema.model_name`) AND registers a DAG dependency — dbt runs upstream models first; hardcoding a `schema.table` reference loses the dependency and dbt may run downstream models before their upstream finishes → wrong run order / runtime error. Also: environment / catalog portability (dev vs prod schemas resolve correctly via `ref()`; hardcoded strings break on env switch). `source()` is the analogous macro for raw external (non-dbt-managed) tables — also registers a node in the lineage graph and supports freshness checks. From Trino's perspective the final SQL is identical — Trino never sees `{{ ref(...) }}`; it sees the fully-qualified relation that dbt expanded the macro into. "All three execute identically from Trino's perspective; `ref()` unlocks dependency resolution + portability + test-gating."

**VERIFIED** against [docs.getdbt.com/reference/dbt-jinja-functions/ref](https://docs.getdbt.com/reference/dbt-jinja-functions/ref) (ref returns a Relation object with table/schema/name; lets you change deployment schema via configuration; uses references to automatically build the dependency graph) + [docs.getdbt.com/best-practices/best-practice-workflows](https://docs.getdbt.com/best-practices/best-practice-workflows) (use `ref()` when selecting from another model, not direct relation references; ensures dbt can track dependencies during parsing). All claims source-aligned.

No imported-prior, no broken-secondary, no over-warning, no fabrication. Minor Clar/Compl shaves only — could have surfaced that `ref('model')` cross-project / cross-package form is `ref('project', 'model')` (2-arg overload) for full completeness, but not load-bearing for this engineer's monorepo question.

### Q4 — Oracle `ROWID` dedup → Trino — **4.875 STRONG PASS**

Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 4.75.

**Setup**: Oracle dedup pattern `WHERE a.ROWID != b.ROWID` on a self-join to eliminate self-pairs / duplicate rows. Trino has no `ROWID`. Right rewrite?

**Responder**: Trino has NO `ROWID` pseudocolumn (Iceberg/Trino are columnar, no per-row physical address). **READ-side dedup**: `ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY created_at)` subquery, then outer `WHERE rn = 1`. **IN-PLACE** dedup: CTAS to a new clean table + rename (atomic swap), OR `MERGE INTO target USING (rn>1) WHEN MATCHED THEN DELETE`. **DO-NOT**: window function in `WHERE` directly (parser allows only certain expressions in WHERE; window must live in SELECT or be wrapped in a subquery); no `QUALIFY` in Trino 467 (Snowflake/BigQuery only).

**VERIFIED**: no `ROWID` pseudocolumn in Trino (engineer's Oracle-instinct correctly invalidated); `ROW_NUMBER() OVER (PARTITION BY key ORDER BY ts) ... WHERE rn=1` is the canonical Trino dedup form per r07 / r23 / r27; no `QUALIFY` in Trino 467 (responder's defang is correct — `QUALIFY` is Snowflake/BigQuery/Teradata, not Trino). CTAS+rename and `MERGE ... WHEN MATCHED ... DELETE` both work on Iceberg via Trino 467 (Iceberg supports row-level MERGE/DELETE on this stack).

No imported-prior, no broken-secondary, no over-warning, no fabrication. Pin-perfect comprehensive dedup canonical with correct defangs.

---

## Topic checklist updates (rubric)

| Topic | Pre | This iter | Post | Δ | Status |
|---|---|---|---|---|---|
| SQL query best practices for OLAP (Q1 — hash/surrogate parity) | 4.5947/315 | 2.875 | **4.5893/316** | −0.0054 | PASSED (margin +1.0893) |
| Query performance regression diagnosis (Q2 — EXPLAIN variant for pre-run estimate) | 4.0612/28 | 2.625 | **4.0107/29** | −0.0505 | PASSED (margin +0.5107, REMAINS THINNEST REQUIRED TOPIC, biggest single-iter drop since iter1305-Q3 same-topic) |
| Improving complex SQL performance on Trino with dbt (Q3 — ref/source/DAG) | 4.4185/105 | 4.875 | **4.4228/106** | +0.0043 | PASSED (margin +0.9228) |
| Oracle PL/SQL → dbt + Trino (Q4 — ROWID dedup) | 4.5010/287 | 4.875 | **4.5023/288** | +0.0013 | PASSED (margin +1.0023) |

All topics remain PASSED. Query performance regression diagnosis takes the biggest hit (−0.0505) and remains the thinnest required topic — margin still +0.51 above the 3.5 threshold, but the second iter1305-family drop in 5 iters (iter1305-Q3 was 2.375 same topic). Both Q1 and Q2 are below the 3.5 per-question pass threshold; iteration-average is rescued by Q3+Q4.

---

## Watches

**NEW LOW SOFT WATCH `iter1310-Q1 Postgres-vs-Trino md5 case-parity (Postgres lowercase / Trino UPPERCASE / use lower() for parity)`**: re-probe in 4-8 iters under varied "is my Trino md5 the same as Postgres md5" / "join legacy Postgres-hashed keys against Trino-hashed keys" / "why doesn't my Trino surrogate key match the Postgres one" framings. If recurs (2+ instances) with same "both uppercase" false claim → escalate from LIGHT to firmer FIX-A on the case-parity callout. **Recommended LIGHT FIX-A on this iter**: add a Postgres-parity case-difference callout to r23 §1162-1180 (the LEADING CANONICAL hash-a-string block) and back-cross-ref at r27 §4.5A surrogate-key — explicit "Postgres lowercase, Trino uppercase, wrap with `lower(...)` to match Postgres exactly." First-occurrence on a silent-breakage class (mismatched hash keys → zero-row join with no error) — additive callout is warranted.

**NEW LOW SOFT WATCH `iter1310-Q2 EXPLAIN ANALYZE recommended when engineer asks for PRE-RUN / BEFORE-running scan estimate`**: re-probe in 4-8 iters under varied "without running the query" / "ahead of time" / "dry run" / "estimate before executing" / "will Trino read the whole table" / "preview the scan" framings. If recurs (2+) → escalate from LIGHT to firmer FIX-A. **Recommended LIGHT FIX-A on this iter**: add a keyword-magnet routing block near the EXPLAIN-variant table in r23 §2487 and/or r18 §831 explicitly catching the "BEFORE running" / "ahead of time" phrasings and routing to plain `EXPLAIN` / `EXPLAIN (TYPE IO, FORMAT JSON)` — NOT `EXPLAIN ANALYZE`. Content is already present in both resources; this is purely a findability/keyword-magnet add. First-occurrence on a literal asked-question wrong-tool slip with engineer-cost consequence (running EXPLAIN ANALYZE re-pays the 40-second cost the engineer was avoiding).

**CARRY**: iter1309-Q2 LAG-grain LOW (re-probe 4-8 / FIX-A at 2+ recur); iter1303-Q2 SUM(SUM); iter1300-Q2 spill-causality; iter1308-Q4 NULL-order-false-premise-light; iter1307-Q4 trailing-space-LOW.

**CLOSED**: iter1305-Q3 columnar-projection HARD watch — closed POSITIVELY at iter1309-Q1 (responder reached COLUMNAR PROJECTION on first pass at explicit projection-isolated re-probe). No new closures this iter.

---

## Net assessment

- **Two FAILs in one iteration is the biggest single-iter quality drop in many sweeps** (most recent sweep with 2 sub-3.5 questions was iter1305 with one 2.375). Both FAILs are on the same shape: engineer asks a precise side-question, responder gives a mechanism-rich answer that addresses an adjacent question while getting the literal asked sub-question wrong.
- Overall iteration avg 3.8125 clears the 3.5 threshold and all topics remain PASSED. But the **margin compression on the thinnest topic** (Query performance regression diagnosis −0.05) is the second iter1305-family drop in 5 iters — worth flagging as a soft trend, not a regression.
- **Recommended teacher actions this iter (BOTH LIGHT)**:
  1. r23 §1162-1180 hash-string-canonical: add Postgres-parity case-difference callout + `lower(to_hex(md5(...)))` for Postgres compatibility. Back-cross-ref at r27 §4.5A surrogate-key §.
  2. r23 §2487 EXPLAIN-variant table AND/OR r18 §831 "when to use each": add a leading-canonical routing block with keyword anchors "BEFORE running / ahead of time / dry run / without executing / preview the scan / estimate scan size" → route to plain `EXPLAIN` or `EXPLAIN (TYPE IO, FORMAT JSON)`, NOT `EXPLAIN ANALYZE`.
- Both fixes are additive, low-risk for over-attraction. Q3 + Q4 are clean carry-forward STRONG signals — no fix needed.
