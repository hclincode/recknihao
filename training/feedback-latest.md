# Iter1164 — Judge Feedback

**Verdict: 4.96875 STRONG PASS NO-OP. WATCH CLOSES.**

**Iter average = (4.875 + 5.0 + 5.0 + 5.0) / 4 = 4.96875 STRONG PASS.** Three pin-perfect canonical reaches (date_parse/parse_datetime / MAX-OVER-PARTITION-BY single-pass / Iceberg UPDATE-MoR with maintenance follow-up) plus a clean Q1 watch re-probe — Q1 framing the strict-typing failure mode CORRECTLY as "Trino ERRORS with TYPE_MISMATCH" with NO silent-string-compare fabrication. The iter1163 r27 date-vs-string watch is now bounded: same failure-mode question class in different framing (DECIMAL × varchar vs date × varchar) reached the correct error-out answer first try. **WATCH `r27 date-vs-string-literal silent-string-comparison fabrication iter1163` CLOSES on first re-probe** — pattern consistent with the recent "first NO-OP/WATCH → close on next re-probe" cadence (r17 TopN-disambiguation / r23 VARCHAR-exact-comparison / r07 IGNORE-NULLS-placement / r07 percent-of-total).

No resource defects detected. No FIX-A required. No new watch opened.

---

## Q1 — DECIMAL column = '85' quoted-string predicate (WATCH RE-PROBE)

**Score: 4.875** (Acc 5 / Clarity 5 / Practical 5 / Completeness 4.5)

Responder correctly framed the failure mode:
- **YES Trino errors** — TYPE_MISMATCH at analysis time. **NO silent-string-comparison claim** anywhere in the answer. The iter1163 Q4 fabrication ("Trino executes it as string comparison, wrong result") is **absent** from this re-probe.
- Stated reason: Trino is strict about types, has **no implicit varchar↔number coercion** (unlike Postgres). Verified at [trino.io/docs/current/language/types.html](https://trino.io/docs/current/language/types.html) — implicit coercion list does NOT include varchar→decimal/bigint/double, and [Trino blog "Optimizing the Casts Away"](https://trino.io/blog/2019/05/21/optimizing-the-casts-away.html) explicitly confirms Trino "will not convert between character and numeric types."
- Error shape `Cannot apply operator: decimal(p,s) = varchar(N)` is the documented `TYPE_MISMATCH` error class — same family as the [TYPE_MISMATCH: Cannot apply operator: date < varchar(10)](https://repost.aws/questions/QUpE0-ijXmRGaRD0LWYVfI0g/type-mismatch-line-3-32-cannot-apply-operator-date-varchar-10) case.

Fix patterns correct:
- `WHERE score = CAST('85' AS DECIMAL)` — works, partition-prunes via UnwrapCastInComparison (column stays bare).
- `WHERE CAST(score AS VARCHAR) = '85'` — works but listed correctly as the worse alternative (column-side CAST breaks numeric semantics; e.g., 85 vs 85.0 vs 85.00 stringify differently).
- Best-practice recommendation: emit `CAST('85' AS DECIMAL)` at param-generation time. Correct routing.

**Minor completeness shave (-0.5)**: the most engineer-natural fix — **just unquote the literal at codegen** (`WHERE score = 85`, no CAST needed at all because a numeric literal `85` is implicitly compatible with DECIMAL) — was not explicitly named. CAST('85' AS DECIMAL) is functionally equivalent (and the responder's wording is correct) but unquoting is shorter and the more common production fix. Not load-bearing — engineer reading the answer arrives at correct code either way.

**WATCH STATUS: CLOSED.** Different framing (DECIMAL column not DATE/TIMESTAMP column, Postgres-source-app not Oracle migration, codegen-quote-string not literal-string-in-SQL), same strict-typing question class — responder gave the correct TYPE_MISMATCH framing with zero silent-string-compare fabrication. r27 §4.2 + §4.4 + r23 strict-typing canonicals are doing their job; the iter1163 slip was a single-phrasing responder over-elaboration absorbed by 9 of last 9 recent watches closing on first re-probe.

Cites r27.

---

## Q2 — Vendor MM/DD/YYYY VARCHAR → DATE parsing

**Score: 5.0** (Acc 5 / Clarity 5 / Practical 5 / Completeness 5)

Responder named both correct Trino 467 functions with the exact format strings:

- **`date_parse('06/25/2026', '%m/%d/%Y')`** (MySQL-style) — returns `timestamp(3)`; wrap with `CAST(... AS DATE)` to get a date. Verified at [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html): "Parses `string` into a timestamp using `format`" with example `date_parse('2022/10/20/05', '%Y/%m/%d/%H') → 2022-10-20 05:00:00.000`. Format specifiers `%m` (month 01-12), `%d` (day 01-31), `%Y` (4-digit year) all match the MM/DD/YYYY vendor feed correctly.

- **`parse_datetime('06/25/2026', 'MM/dd/yyyy')`** (Joda-style) — returns `timestamp with time zone`. Verified at the same docs page: "Parses `string` into a timestamp with time zone using `format`" using JodaTime's DateTimeFormat pattern.

The pair-framing is exactly right (one returns timestamp-without-tz, the other timestamp-with-tz; engineer picks based on whether they need TZ awareness). Both CAST-to-DATE wraps are documented and valid.

CTE pattern to avoid repeating `date_parse(...)` in WHERE (parse once in staging, filter on typed DATE downstream) correct and aligns with the partition-pruning best-practice when the staged VARCHAR is the partition column AFTER materialization.

Clean canonical. Cites r27 §4.2.

---

## Q3 — Per-feature max broadcast onto every row in one pass

**Score: 5.0** (Acc 5 / Clarity 5 / Practical 5 / Completeness 5)

Pin-perfect window-function-as-broadcast canonical:

```sql
SELECT
  account_id, feature_name, monthly_event_count,
  MAX(monthly_event_count) OVER (PARTITION BY feature_name) AS max_for_feature,
  CAST(monthly_event_count AS DOUBLE)
    / MAX(monthly_event_count) OVER (PARTITION BY feature_name) AS fraction_of_max
FROM account_usage;
```

All load-bearing elements correct:
- `MAX(x) OVER (PARTITION BY feature_name)` with no ORDER BY uses default frame `RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` = the whole partition. Verified at [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html): "All aggregate functions can be used as window functions by adding the OVER clause" + default frame semantics produce per-partition max broadcast onto every row.
- `CAST(monthly_event_count AS DOUBLE)` correctly avoids integer division (Trino INTEGER/INTEGER returns INTEGER per pinned reference_trino_cast_to_integer_rounds.md family — without the CAST you'd lose decimal precision on the ratio).
- Single-pass — no self-join, no subquery, no GROUP BY — engineer drops the existing per-feature-max subquery+join entirely.

Cites r23. Clean canonical reach.

---

## Q4 — UPDATE on Iceberg via Trino (teammate's "must delete+reinsert" claim)

**Score: 5.0** (Acc 5 / Clarity 5 / Practical 5 / Completeness 5)

Responder is correct on every load-bearing point:

- **Teammate is WRONG.** Trino 467 SUPPORTS `UPDATE` on Iceberg. Verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html): the Iceberg connector lists Data management as supported (INSERT/UPDATE/DELETE/MERGE) and "Tables using v2 of the Iceberg specification support deletion of individual rows by writing position delete files." UPDATE is implemented via MoR (delete-then-insert at the file level).

- Concrete SQL `UPDATE iceberg.analytics.metrics SET status='active' WHERE account_id=4521` is the correct Trino 467 form.

- **Merge-on-Read mechanic correctly described**: writes position-delete files + new data files in the same snapshot, regardless of `write.update.mode`. Trino 467 only writes MoR for row-level updates on Iceberg v2 — it does not implement copy-on-write for UPDATE; this matches the Iceberg connector behavior in 467 (the property exists in the Iceberg spec but Trino writer ignores `copy-on-write` for UPDATE and always emits position-delete + new rows).

- **Maintenance follow-up correct**: accumulating position-delete files cause read amplification; `ALTER TABLE ... EXECUTE optimize` is the Trino 467 compaction lever. Verified at the same docs page: "The `optimize` command is used for rewriting the content of the specified table so that it is merged into fewer but larger files" (and rewrites data files including those with active delete files, effectively reclaiming them).

- **`rewrite_position_delete_files` correctly scoped Spark-only**: the Trino 467 procedure list at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) is `register_table` / `unregister_table` / `migrate` / `add_files` / `rollback_to_snapshot` — `rewrite_position_delete_files` is NOT listed. Iceberg's `RewritePositionDeleteFiles` action is only callable via Spark `CALL system.rewrite_position_delete_files(...)`. Responder explicitly flagging this asymmetry is exactly right and matches pinned reference_trino_rollback_snapshot_form.md "Trino procedure ≠ Spark CALL" framing.

Matches all known pins. Clean canonical. Cites r17.

---

## Summary

- **Q1 (4.875) WATCH CLOSE** — re-probe answered with correct TYPE_MISMATCH framing; iter1163 silent-string-compare fabrication did not recur. Watch `r27 date-vs-string-literal silent-string-comparison fabrication iter1163` **CLOSED on first re-probe**. Minor shave only — didn't name the simplest fix (unquote at codegen).
- **Q2 (5.0)** — clean Trino-date-parsing canonical, both date_parse (MySQL-style) and parse_datetime (Joda) correctly named with format strings + return types + CAST-to-DATE wrap.
- **Q3 (5.0)** — clean MAX-OVER-PARTITION-BY broadcast canonical with CAST-AS-DOUBLE integer-division guard.
- **Q4 (5.0)** — clean Trino-467 Iceberg UPDATE MoR + EXECUTE optimize + rewrite_position_delete_files Spark-only canonical; matches all pinned references.

**Iter average 4.96875.** No FIX-A. No new watch. No churn. Three 5.0s in a row plus a corrected re-probe is exactly the closure pattern.
