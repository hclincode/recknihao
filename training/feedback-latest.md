# Judge Feedback — iter1073 (2026-06-18)

Stack: Trino 467 + Iceberg + Hive Metastore + MinIO + Spark + dbt-trino + OPA.

**Overall: 4.69 / 5.00 — PASS** (threshold 3.5; margin +1.19)

Verified BOTH directions against RAW git-tag 467 source:
- datetime.md — https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/datetime.md
- map.md — https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/map.md
- select.md — https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/sql/select.md
- aggregate.md — https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/aggregate.md
- connector/iceberg.md — https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/connector/iceberg.md

Zero source-verified dialect defects. Clean sweep.

---

## Q1 — safe read of maybe-missing map key (epoch-ms) + last-30-days compare — 4.75
**Accuracy 5 / Completeness 4.5 / Clarity 5 / Actionability 5**

CONFIRMED both directions vs map.md + datetime.md:
- `element_at(properties,'trial_end_ms')` returns NULL on a missing key ("Returns value for given `key`, or `NULL` if the key is not contained in the map"); the `properties['trial_end_ms']` subscript THROWS ("This operator throws an error if the key is not contained in the map"). Responder's diagnosis (subscript = the error the user saw; element_at = safe) is exactly correct — the RIGHT direction (contrast iter1071 Q2, which mislabeled subscript as NULL-returning).
- `CAST(... AS BIGINT) / 1e3` — `1e3` is a DOUBLE literal so the division is double; fine for `from_unixtime`.
- `from_unixtime` expects SECONDS ("unixtime is the number of seconds since 1970-01-01 00:00:00 UTC"), so dividing epoch-ms by 1e3 is correct; it returns `timestamp(3) with time zone` (all overloads confirmed). The tz-timestamp vs `current_timestamp - INTERVAL '30' DAY` comparison is valid (current_timestamp is also tz-aware).

Minor completeness: `from_unixtime(...)` in WHERE is not partition-prunable on the raw value, but the source is a map value not a partition column, so negligible here.

## Q2 — COUNT DISTINCT users per array tag, all tags at once — 4.875
**Accuracy 5 / Completeness 5 / Clarity 4.5 / Actionability 5**

CONFIRMED vs select.md: `UNNEST(device_tags) AS t(tag)` yields one row per element; `CROSS JOIN UNNEST` drops rows whose array is empty/NULL ("UNNEST returns zero entries when the array/map is empty/null"); `LEFT JOIN UNNEST(...) AS t(tag) ON TRUE` preserves them ("LEFT JOIN is preferable in order to avoid losing the row..."). `GROUP BY tag` + `COUNT(DISTINCT user_id)` valid. Single alias for an array unnest is correct. Clean.

## Q3 — pivot plan_name rows into per-plan revenue columns — 4.625
**Accuracy 5 / Completeness 4.5 / Clarity 4.5 / Actionability 5**

CONFIRMED: Trino 467 has NO `PIVOT` keyword (correctly stated). Both conditional-aggregation forms valid:
- `SUM(CASE WHEN plan_name='starter' THEN monthly_revenue ELSE 0 END)` — standard.
- `SUM(monthly_revenue) FILTER (WHERE plan_name='starter')` — VERIFIED in aggregate.md: "The `FILTER` keyword can be used to remove rows from aggregation processing ... supported for all aggregate functions."

Both compute per-plan revenue per customer with `GROUP BY customer_id`. Note one informal semantic difference (not penalized as egregious): the CASE form emits `0` for a customer with no rows of a plan, while FILTER emits `NULL` (SUM over empty = NULL). The "both forms equivalent / identical plans" claim is loose on this NULL-vs-0 edge but harmless for the asked use case. Minor clarity ding only.

## Q4 — inspect/restore Iceberg invoices after accidental delete — 4.50
**Accuracy 5 / Completeness 4 / Clarity 4.5 / Actionability 4.5**

ROLLBACK FORM VERDICT — CORRECT for 467. CONFIRMED vs connector/iceberg.md:
- `iceberg.analytics."invoices$snapshots"` metadata table exists; columns include `committed_at` (timestamp(3) with tz), `snapshot_id` (bigint), `parent_id`, `operation` (varchar), `summary` (map(varchar,varchar)). The four selected columns are all real.
- `CALL iceberg.system.rollback_to_snapshot('analytics', 'invoices', <snapshot_id>)` — POSITIONAL 3-arg form is correct for 467 (docs example: `CALL example.system.rollback_to_snapshot('testdb','customer_orders', 8954597067493422955)`). Responder's warning that the Spark named-arg form (`table=>..., snapshot_id=>...`) is wrong in Trino is accurate. There is NO `ALTER TABLE ... EXECUTE rollback_to_snapshot` form in 467 (that is a later 469+ form) — responder correctly avoided it.
- Notes sound: metadata-only pointer move; expire_snapshots window; rollback loses writes landed after the bad delete → surgical DELETE/restore-by-insert instead.

COMPLETENESS GAP (minor): the user also asked to "look at what the table contained before" — read-only inspection. The canonical is `SELECT * FROM iceberg.analytics.invoices FOR VERSION AS OF <snapshot_id>` (or `FOR TIMESTAMP AS OF TIMESTAMP '...'`), both confirmed present in 467. The responder found the snapshot and jumped straight to rollback without showing the non-destructive time-travel SELECT to inspect/verify first. Rolling back before inspecting is riskier than the asked "look at prior contents" implies. Completeness 4.0.

---

## Cross-cutting
No `::`-cast misuse / QUALIFY / false-semi-join / fabricated function / regex-backslash / INTERVAL quarter-week / OFFSET-before-LIMIT / over-warning folklore / broken-secondary-alternative. Imported-prior risk families answered correctly (element_at-vs-subscript direction, from_unixtime-tz seconds, rollback_to_snapshot positional CALL form).

RECOMMENDATION = DEFAULT NO-OP (margin +1.19). The Q4 missing FOR VERSION AS OF read-only inspection is the single actionable item; it is a per-instance completeness gap, not a missing canonical (time-travel SELECT is well-covered). No resource edit, no commit. MUST NOT bump state.json (already 1073).
