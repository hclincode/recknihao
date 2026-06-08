# Judge Feedback — iter698

**Phase**: extended | **Final iterations remaining**: 0 | **Score governance**: overall average

---

## Per-question scores

### Q1 — Month-over-Month revenue (FIX-A2 RE-PROBE)
| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | LAG-on-monthly-CTE form: `date_trunc('month', paid_at)` -> CTE pre-aggregates to one row per calendar month, then `LAG(total_revenue) OVER (ORDER BY month_start)` references the IMMEDIATELY PRECEDING calendar month. SINGLE `* 100.0` multiply (no double-100). NULLIF div-by-zero guard. Verified vs trino.io/docs/467/functions/window.html -- `lag(x)` defaults to offset=1 row, requires `ORDER BY`. No `month=current AND year=current-1` YoY form. No per-row self-join. |
| Completeness | 5 | Returns rolling time series (`ORDER BY month_start`), exposes both `prev_month_revenue` and `mom_growth_pct`. Explains the load-bearing semantic (LAG counts rows, not days, so pre-agg makes LAG(metric,1) = previous calendar month). |
| Clarity | 5 | Names CTE clearly; explanation of NULLIF and the row-vs-date distinction; no jargon left unexplained. |
| Actionability | 5 | Copy-paste runnable Trino 467 SQL against the engineer's `payments(amount, paid_at)` schema. |

**FIX-A2 STATUS: CLOSED.** The iter697 Q2 YoY-shape-applied-to-MoM-question regression did NOT recur. Responder produced the consecutive-month comparison correctly. The new Sub-canonical at r07:2486+ plus the defanged DO-NOT-WRITE table routed correctly.

### Q2 — approx_distinct for fast unique-visitor count
| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 4.5 | Signature, HyperLogLog attribution, 2.3% standard error all verified vs trino.io/docs/467/functions/aggregate.html (docs verbatim: "should produce a standard error of 2.3%"). The "Think of it like statistical sampling, not an approximation over the data" line is slightly loose -- HLL is a hash-bit-pattern cardinality sketch, NOT sampling -- but the immediate "not an approximation over the data" caveat partially defangs it. Minor accuracy nick only. CRITICALLY: did NOT cross approx_distinct with approx_percentile (the iter697 FIX held from the opposite side -- validates the sketch-distinction from BOTH sides). |
| Completeness | 5 | Per-day grouping (the realistic dashboard shape), error envelope worked through with concrete numbers (1M +/- 23k), 10-50x speedup framing, and the "for exact financial reporting, stick with COUNT(DISTINCT)" caveat. |
| Clarity | 4.5 | "Tiny fixed-size fingerprint per worker and merges them" is good intuition. The "statistical sampling" lead-in could mislead a careful reader -- flag only. |
| Actionability | 5 | Drop-in SELECT, immediate ~10-50x win on 800M rows; clear decision rule for when to NOT use it. |

### Q3 — Extract JSON fields safely
| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | `json_extract_scalar(json, '$.key')` signature + NULL-on-missing-key both verified vs trino.io/docs/467/functions/json.html. JSONPath `$.plan` syntax correct. MAP alternative `element_at(map, key) -> NULL on missing` verified vs trino.io/docs/467/functions/map.html (docs verbatim: "Returns value for given key, or NULL if the key is not contained in the map"). Correctly distinguished from the array-subscript-out-of-bounds-errors trap; did NOT conflate. |
| Completeness | 5 | Three field extractions covering string / bool / numeric, missing-key safety call-out, AND the schema-evolution upgrade path (promote to top-level columns at write time for partition pruning + columnar compression), AND the MAP-column alternative. |
| Clarity | 5 | One-line per concept; no unexplained jargon. |
| Actionability | 5 | Runs immediately against the engineer's `subscriptions.metadata` raw-JSON column. |

### Q4 — Ordered event sequence (funnel) via MATCH_RECOGNIZE
| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 4.5 | Verified vs trino.io/docs/467/sql/match-recognize.html -- PARTITION BY / ORDER BY / MEASURES / ONE ROW PER MATCH / AFTER MATCH SKIP TO NEXT ROW / PATTERN / DEFINE all valid 467. `FIRST(event_time)` in DEFINE: docs verbatim "Boolean expressions in the DEFINE clause allow the same special syntax as expressions in the MEASURES clause" -- so spec-allowed, even though the docs do not show an explicit DEFINE example using FIRST(). Timestamp + INTERVAL '30' MINUTE is documented arithmetic. The 30-minute time bound on BOTH `created_project` and `invited_teammate` correctly enforces a session window. Minor: `signup AS event_name='signup' AND session_id IS NOT NULL` introduces a session_id column the question did not name -- a reasonable assumption when the question says "same session" but not strictly required. |
| Completeness | 5 | Captures the FULL sequence (signup -> created_project -> invited_teammate), funnel_start/funnel_end measures, session-window bound, ONE ROW PER MATCH = one row per completer, and the cost framing vs 3-join cascade. |
| Clarity | 5 | "Regex for SQL rows" is an outstanding one-line analogy; PATTERN/DEFINE walked through. |
| Actionability | 5 | Engineer can paste against `user_events(user_id, event_name, event_time, session_id)`. |

---

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 MoM | 5.0 | 5.0 | 5.0 | 5.0 | 5.000 |
| Q2 approx_distinct | 4.5 | 5.0 | 4.5 | 5.0 | 4.750 |
| Q3 JSON extract | 5.0 | 5.0 | 5.0 | 5.0 | 5.000 |
| Q4 MATCH_RECOGNIZE | 4.5 | 5.0 | 5.0 | 5.0 | 4.875 |

Sub-score sum cross-check: 5+5+5+5 + 4.5+5+4.5+5 + 5+5+5+5 + 4.5+5+5+5 = 78.0 / 16 = **4.875**
Per-Q avg cross-check: (5.000 + 4.750 + 5.000 + 4.875) / 4 = 19.625 / 4 = **4.90625**

**Overall average = 4.875** (sub-score governance per prompt; per-Q-avg of 4.906 agrees within rounding).

**Verdict: STRONG PASS** (threshold 3.5, margin +1.375).

---

## FIX status callouts

- **FIX-A2 (MoM month-over-month, iter697 Q2 regression)**: **CLOSED.** Responder produced LAG-on-monthly-CTE consecutive-month comparison, single 100.0, NULLIF guard. Did NOT regress to the year(current_date)-1 YoY shape. The new Sub-canonical block + DO-NOT-WRITE defanged snippets at r07:2486+ routed correctly.
- **iter697 approx_percentile fix (held)**: COMPLEMENT-VALIDATED here in Q2. Responder correctly attributed HyperLogLog + 2.3% to approx_distinct (not crossed with approx_percentile). The sketch-distinction now holds from BOTH sides.
- All ~260 locks (iter534-697) preserved -- no regression.

---

## New findable-but-missing gaps for iter699

**No critical new gaps.** All four answers landed at or above 4.75 per-Q. Possible probing angles (optional, not required):

1. **"Statistical sampling" analogy nit (Q2)**: minor -- the responder's lead-in "Think of it like statistical sampling" could mislead. If iter699 wants to harden the sketch-mental-model, add a one-line "HLL is NOT sampling -- it counts hash-bit-pattern observations on the WHOLE input" anchor near the approx_distinct canonical so the responder reaches for the more accurate framing. Not a regression risk on its own; flag only.

2. **MATCH_RECOGNIZE schema-fit (Q4)**: responder slipped in `session_id IS NOT NULL` without the question naming a session_id column. Reasonable assumption ("same session") but not strictly required by the question. Optional polish, not a real gap.

**Recommendation for iter699**: probe an unrelated near-threshold area (cost / partitioning / a 4.5-bar federation/CBO topic) rather than re-probe these four -- all four are now solid from multiple angles.

---

## Production-environment fit

All answers fit Trino 467 + Iceberg + MinIO + on-prem k8s. No cloud-only or Spark-only constructs. No auth/permission scope creep. All SQL is Trino-467 dialect (no QUALIFY, no Snowflake/BigQuery idioms).
