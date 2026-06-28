# Iteration 1217 — Judge Feedback

**Verdict: 4.83 STRONG PASS / NO-OP.** Q1 iter1215 compression_codec-477-cutoff WATCH **CLOSES CLEANLY** on first re-probe (5.0). Q2 cumulative-share-with-empty-OVER() 5.0. Q3 dbt-build-interleaved 5.0. Q4 translate-exists-1:1-Oracle core correct (assumed-absence myth correctly AVOIDED) but **EXAMPLE OUTPUT BUG** — the phone-strip example's SQL doesn't produce the stated output (recall-ceiling slip, NOT resource-sourced). No FIX-A.

---

## Per-question scores

### Q1 — `ALTER TABLE SET PROPERTIES compression_codec='ZSTD'` on Trino 467 / Iceberg / MinIO (WATCH RE-PROBE)

**Score: 5.0** (Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0)

**iter1215 `compression_codec-477-cutoff` 9-file FIX-A REACHES CLEANLY — WATCH CLOSES on first re-probe.**

Every load-bearing fact verified against [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) (WebFetched this iter):

1. **`SET PROPERTIES compression_codec='ZSTD'` ERRORS on 467** — table-properties section lists `format`, `format_version`, `partitioning`, `sorted_by`, `location`, `data_location`, `orc_bloom_filter_columns`, `orc_bloom_filter_fpp`, `parquet_bloom_filter_columns`, `object_store_layout_enabled`, `extra_properties`. `compression_codec` is **ABSENT**. Responder correctly cites the parse error wording `table property 'compression_codec' does not exist`.

2. **Added in Trino 477 via PR #25755** — verified iter1215. Responder correctly gates the cutoff.

3. **No `iceberg.compression_codec` SESSION property on 467 either** — verified WebFetch (no Session-properties entry matching). Responder's "no per-session/per-table override on 467" matches docs. (Session-prop wiring is 473+ per PR #24851; the post-477 ecosystem has both forms, but on 467 NEITHER is present — only catalog config.)

4. **Trino-written files → catalog config `iceberg.compression-codec` in `etc/catalog/iceberg.properties`, RESTART required, values `NONE / SNAPPY / LZ4 / ZSTD / GZIP`, default `ZSTD`** — VERIFIED verbatim "The compression codec used when writing files. Possible values are: NONE, SNAPPY, LZ4, ZSTD, GZIP" + default `ZSTD`. Responder pins every detail.

5. **Spark-written files → `ALTER TABLE ... SET TBLPROPERTIES ('write.parquet.compression-codec'='zstd')`** — VERIFIED Iceberg native write property; the responder correctly routes through Spark since Spark is the on-prem ingestion engine per `prod_info.md`. Correct note: "Trino has no TBLPROPERTIES" (Trino uses `WITH(...)` / `SET PROPERTIES`; TBLPROPERTIES is Spark/Hive syntax).

6. **`SELECT key, value FROM "events$properties" WHERE key LIKE '%compression%'`** — inspection canonical correct (Iceberg `$properties` metadata table valid on Trino 467; Spark write of compression knob lands in `write.parquet.compression-codec` native Iceberg key).

7. **Future-writes-only semantics** — correctly stated; existing Parquet files keep old codec. Re-compress via `EXECUTE optimize` (Trino) OR `CALL iceberg.system.rewrite_data_files(...)` (Spark) — both correct routing.

**Production-stack alignment**: catalog config requires server restart on this on-prem Trino 467 deployment (acceptable for an infrequent compression switch); Spark-side TBLPROPERTIES fits the Spark+Iceberg+HMS ingestion stack per `prod_info.md`. The combined Trino+Spark answer is exactly what the engineer needs (both write paths land on the same table).

**Engineer outcome**: does NOT run the broken `ALTER TABLE ... SET PROPERTIES compression_codec='ZSTD'` (avoids parse-error rabbit hole); instead updates `etc/catalog/iceberg.properties` + restarts coordinator, AND ships the Spark-side TBLPROPERTIES change in the same PR — single coordinated codec switch covering both writers.

**WATCH STATUS**: `iter1215 compression_codec-477-cutoff` — **CLOSED on first re-probe** (11th consecutive watch closure in 1st-re-probe-CLOSE pattern). Storage-tiering topic margin restored (was thinnest at 4.0848/14 after iter1215 hit, this 5.0 lifts it).

---

### Q2 — Per-customer total revenue + cumulative-share-of-grand-total (Pareto / 80%)

**Score: 5.0** (Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0)

Pin-perfect cumulative-share-of-grand-total canonical. Verified valid Trino 467 against [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html) + window-frame syntax:

1. **Aggregate-then-window** — inner subquery `SELECT customer_id, SUM(amount) AS total_revenue FROM orders GROUP BY customer_id` collapses orders to per-customer rows BEFORE the window pass. Correct pattern (windows on aggregated rows, not raw events).

2. **Running cumulative** — `SUM(total_revenue) OVER (ORDER BY total_revenue DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` is the standard Pareto-running-total form. ROWS bound (not RANGE) handles ties row-by-row deterministically. Equivalent `ROWS UNBOUNDED PRECEDING` shorthand for cumulative_pct works identically.

3. **Grand total via empty OVER()** — `SUM(total_revenue) OVER ()` returns the same grand-total scalar broadcast to every row. **The key insight the engineer was missing** — no self-join, no CTE-scalar-cross-join, no two queries. Empty OVER() partition + no frame = global aggregate over all rows of the window's input.

4. **Pct + ROUND** — `ROUND(100.0 * running / grand_total, 2)` correct Trino `round(double, integer)` overload. Multiplication by `100.0` (double) forces double arithmetic, avoids int truncation. (Bigint sum / bigint sum would integer-divide; the `100.0` coerce is load-bearing.)

5. **Threshold filter via outer subquery** — `SELECT * FROM (...) WHERE cumulative_pct <= 80` is the Trino 467 way (no QUALIFY clause per pinned iter1216 — window functions can't appear in WHERE). Engineer gets the Pareto-80 row set.

6. **Single query, one table scan, no self-join** — directly answers the engineer's literal hangup ("couldn't get the grand total into the same query without a self-join").

**Engineer outcome**: pastes the pattern verbatim; Pareto-80% top-customer report ships immediately. No re-read of docs needed.

---

### Q3 — `dbt build` vs `dbt run` + `dbt test`: interleaving and downstream-skip behavior

**Score: 5.0** (Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0)

Verified verbatim against [docs.getdbt.com/reference/commands/build](https://docs.getdbt.com/reference/commands/build) (WebFetched this iter):

1. **`dbt build` runs models + tests INTERLEAVED in DAG order, NOT all-models-then-all-tests** — VERIFIED docs verbatim "In DAG order, for selected resources or an entire project." Responder correctly distinguishes this from the engineer's mental model (`run` then `test`).

2. **Test failure SKIPS downstream dependents** — VERIFIED verbatim "Tests on upstream resources will block downstream resources from running, and a test failure will cause those downstream resources to skip entirely. E.g. If `model_b` depends on `model_a`, and a `unique` test on `model_a` fails, then `model_b` will `SKIP`." Responder pins this exactly.

3. **Severity gating** — implicitly correct (responder said "severity = error" causes skip). Could optionally mention `severity: warn` override allows the failure to not block downstream, but not required for the question.

4. **`dbt run` + `dbt test` separately = bad data lands** — correctly framed: `dbt run` does NOT gate on test results, so `model_b` reads bad data from `model_a` before `dbt test` even runs. This is the genuine reason `dbt build` is preferred.

5. **Non-zero exit on test failure** — correctly noted.

6. **Resources: seeds + models + snapshots + tests interleaved** — VERIFIED docs "Snapshots, Models, Seeds, Tests... in DAG order" matches.

**Engineer outcome**: switches CI/CD from `dbt run && dbt test` to `dbt build`; downstream models no longer build off failed-test upstream tables. Single command, build-time gating, non-zero exit propagates to the runner.

---

### Q4 — Oracle `TRANSLATE` → Trino dialect

**Score: 4.3125** (Acc 4.0 / Clar 4.5 / App 4.0 / Compl 4.75)

**Core fact PIN-PERFECT** (and a *positive* — responder correctly AVOIDED the assumed-absence myth this time, consistent with iter1192/iter1198/iter1174 family). **BUT one EXAMPLE OUTPUT BUG** in the phone-strip example — the SQL doesn't produce the stated output. Recall-ceiling responder slip, NOT resource-sourced.

**What landed correctly** (verified against [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html), WebFetched this iter):

1. **`translate(source, from, to) -> varchar` EXISTS in Trino 467** — VERIFIED. Responder said "YES, Trino 467 has translate(...) — EXACT 1:1 of Oracle TRANSLATE, use verbatim." Correctly AVOIDED the assumed-absence imported-prior family (Trino-has-no-X-function-like-Postgres-Oracle) — POSITIVE NOTE, this matches the canonical r27 §4.3-STR-FAMILY DO-NOT-WRITE row.

2. **Semantics: positional char-by-char substitution, chars not in `from` copied** — VERIFIED.

3. **`from`-longer-than-`to` ⇒ extra chars DROPPED** — VERIFIED docs verbatim "If the index of the matching character in the `from` string is beyond the length of the `to` string, the `source` character will be omitted from the resulting string."

4. **Vowel-strip example `translate('hello','aeiou','') → 'hll'` CORRECT** — matches r27 §4.3-STR-FAMILY canonical row verbatim, and matches docs example `translate('abcd', 'a', '')` → `'bcd'`.

5. **SSN-mask example `translate(ssn,'0123456789','##########')` → `'###-##-####'`** — CORRECT (dashes not in `from`, copied through; digits 1:1 to `#`). Matches r27 §4.3 row.

**The example bug (Acc -1.0 / App -1.0)**:

Responder wrote: `translate(phone_number, '()- ', '     ')` (the `to` arg is **5 spaces**) with stated output `'(555) 123-4567' → '5551234567'`.

**This SQL doesn't produce that output.** Each of `'('`, `')'`, `'-'`, `' '` in `from` maps to a SPACE in `to`. So `'(555) 123-4567'` becomes `'  555  123 4567'` (spaces, NOT removed chars). The stated output `'5551234567'` would require `to=''` (empty string — the from-longer-than-to drop case):

```sql
-- CORRECT for removal:
translate(phone_number, '()- ', '')          -- → '5551234567'

-- What the responder wrote (spaces, NOT removal):
translate(phone_number, '()- ', '     ')     -- → '  555  123 4567'
```

Engineer copies the responder's broken example, gets a string full of spaces, has to debug. Bug is internal to the example — responder's OWN strip-vowels example two lines later uses `''` (empty) correctly, so the engineer who reads both examples will catch the inconsistency, but a copy-paste of the phone example fails silently (no parse error, wrong output).

**Resource-source check — RECALL-CEILING, NOT RESOURCE DEFECT.** Grepped `resources/27-oracle-plsql-to-dbt-trino.md` §4.3-STR-FAMILY (lines 1036-1060):
- The canonical row (line 1042) teaches BOTH the mask-with-equal-length-`to` form (`translate('555-1234', '0123456789', '##########')` → `'###-####'`) AND the strip-vowels form (`translate('hello', 'aeiou', '')` → `'hll'`) correctly with empty-string `to` for removal.
- The DO-NOT-WRITE row (line 1056) correctly bans the fabricated "Trino has no TRANSLATE" claim.
- **NO** phone-strip example exists in the resource — the responder INVENTED the `'()- '`-with-5-spaces form. Resource is clean.

Per `feedback_responder_broken_secondary_alternative.md` family — responder nails the LEAD (canonical fact + semantics + correct strip-vowels example) and then APPENDS a broken secondary example. Per-instance one-off, **NO RESOURCE FIX**, no churn warranted.

**Engineer outcome**: gets the right core answer (translate exists, 1:1 Oracle); two of three examples ship; phone-strip example silently malforms output. Engineer who is paying attention catches the contradiction between examples 1 and 2 in the same answer; engineer who copy-pastes blindly debugs the spaces in output. Net actionable, with a documentation hazard.

---

## Cross-question patterns

- **WATCH CLOSE**: iter1215 `compression_codec-477-cutoff` 9-file FIX-A — CLOSED on first re-probe (Q1 5.0). Storage-tiering topic margin lifted off the thin floor.
- **Positive note (assumed-absence reflex)**: Q4 responder correctly said "YES, Trino has translate" — the imported-prior assumed-absence myth (consistently bitten in starts_with / to_char / listagg / array_sum / format_number / migrate / LATERAL families per pinned references) did NOT recur this iter. Consistent with iter1192/iter1198/iter1174 corrections holding.
- **Broken-secondary-alternative slip recurs (Q4)**: `feedback_responder_broken_secondary_alternative.md` family — responder padded a verified-correct LEAD with a self-invented broken `translate(phone, '()- ', '     ')` example. 9th instance (after iter936/iter943/iter948/iter950/iter954/iter1013/iter1019/iter1020). Per pinned policy — per-instance one-off re-probe, NO resource fix, no churn.
- **No imported-prior slip**, no over-warning folklore, no fabricated function/property names.

## Topic routing this iteration

- Q1 → `Storage tiering on Trino+Iceberg+MinIO` (compression_codec-477-cutoff WATCH re-probe — the iter1215 FIX-A topic; restores margin).
- Q2 → `Analytical query patterns on Iceberg+Trino` (cumulative-share-of-grand-total / empty OVER() pattern).
- Q3 → `Improving complex SQL performance on Trino with dbt` (dbt orchestration / build-vs-run+test gating behavior — closest dbt-workflow row).
- Q4 → `Oracle PL/SQL procedure → dbt + Trino SQL migration` (Oracle TRANSLATE → Trino translate dialect rewrite).

## Sources verified against (this iter)

- [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) (table-properties list — `compression_codec` ABSENT; `iceberg.compression-codec` catalog config default ZSTD; no session-property entry)
- [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html) (`translate(source, from, to)` exists; from-longer-than-to drops; empty-`to` strip example verbatim)
- [docs.getdbt.com/reference/commands/build](https://docs.getdbt.com/reference/commands/build) (DAG-order interleave; "a test failure will cause those downstream resources to skip entirely" verbatim)
- [trinodb/trino PR #25755](https://github.com/trinodb/trino/pull/25755) (compression_codec table property added in milestone 477)
- pinned `reference_trino_iceberg_migrate_native.md` (verify-first reflex on Iceberg procedure NATIVE-on-Trino-467 set)
- pinned `feedback_responder_broken_secondary_alternative.md` (Q4 example-bug-on-padded-secondary family)
- r27 §4.3-STR-FAMILY (translate canonical resource — clean, responder slip is recall not source)

## Carry-forward watches

- **iter1215 strpos-3-arg ceiling** — CONFIRMED CEILING, 6-10 iters remaining before next re-probe (no churn per pinned `feedback_synthesis_ceiling_stop_churning.md`).
- **iter1213 session_properties + (+)-mnemonic** — light-monitor, not re-probed this iter.
- **iter1214 retention_days param-fab + expire-vs-planning conflation** — soft watch, 3-7 iters remaining.
- **iter1206 LIKE-on-ROW + $partitions-omission** — soft watch, 3-7 iters remaining.
- **Light-monitors** (no churn): GDPR-Spark-tag, width_bucket, exposures-selector, CURRENT_TIMESTAMP-parens, `::cast`, `--full-refresh` on_table_exists, NVL-coercion.

## Verdict

**4.83 STRONG PASS / NO-OP.** WATCH CLOSES on Q1 (compression_codec FIX-A reaches cleanly, Storage-tiering restored). Q2/Q3 pin-perfect canonicals. Q4 core correct (assumed-absence reflex held positively) with one example-bug recall slip on a padded secondary example (broken-secondary-alternative family). No FIX-A. No churn. Continue breadth probing.
