# Iter161 Q1 — Judge Report

## Question topic
Trino CBO / ANALYZE / Puffin statistics / NDV / join ordering.

## Answer file
/Users/hclin/github/recknihao/training/answers/iter161-q1.md

---

## Technical verification (via WebSearch + Trino docs)

| Claim in answer | Verified? | Notes |
|---|---|---|
| Iceberg auto-collects min/max + row count per file on write | TRUE | Confirmed via Iceberg/Trino docs — file-level min/max and row counts are written by Iceberg writers. |
| Iceberg does NOT auto-collect NDV; ANALYZE is what populates it | TRUE | Confirmed via Trino Iceberg connector docs and AWS Glue/Dremio writeups: NDV is populated by ANALYZE (Theta Sketch) and stored as Puffin blob. |
| ANALYZE writes NDV into a Puffin file in MinIO alongside table metadata | TRUE | Puffin (`apache-datasketches-theta-v1` blob) is the documented storage format for NDV on Iceberg. |
| `ANALYZE TABLE iceberg.analytics.events` syntax | **PARTIALLY WRONG** | The correct Trino syntax is `ANALYZE iceberg.analytics.events` — **no `TABLE` keyword**. The answer uses `ANALYZE TABLE ...` in one place (the “What ANALYZE actually does” section) but later correctly switches to `ANALYZE iceberg.analytics.events` in the Quick Fix step. The inconsistency means a beginner copy-pasting the first form will get a syntax error. |
| `ANALYZE ... WITH (columns = ARRAY['user_id', 'tenant_id'])` | TRUE | Confirmed in Trino Iceberg connector docs as supported syntax. |
| `SHOW STATS FOR iceberg.analytics.events;` | TRUE | Confirmed in Trino SHOW STATS docs. |
| `distinct_values_count` column in SHOW STATS output | TRUE | Confirmed as the documented column name. |
| “Stale stats are worse than no stats” claim | PARTIALLY TRUE / OVERSTATED | In Trino specifically, this is more nuanced: if NDV is wildly stale, the CBO can pick a worse plan than with no stats (when it would fall back to heuristics), but it’s not a universal rule. Acceptable framing for a beginner, but somewhat absolute. |
| “Weekly” cadence recommendation | REASONABLE | Acceptable rule-of-thumb. Real cadence depends on ingest rate. |
| `drop_extended_stats` requirement before re-analyzing subset of columns | NOT MENTIONED | The Trino docs note: if statistics were previously collected for all columns, they must be dropped via `drop_extended_stats` before re-analyzing a subset. The answer doesn't mention this — a real practitioner running ANALYZE on a subset on a table that was previously fully analyzed may hit confusing behavior. Minor completeness gap. |

### Other technical observations
- The "5 seconds instead of 45 minutes" framing for wrong join order is reasonable hyperbole — directionally true for skewed joins.
- Explanation of build-side / probe-side / broadcast-vs-shuffle is accurate and well-pitched for the audience.
- The conceptual flow (CBO needs post-filter selectivity → NDV is the missing piece → ANALYZE populates NDV → stored in Puffin) is technically sound.

---

## Scoring

### Technical accuracy: 4 / 5
Core concepts (CBO, NDV, Puffin, what's auto-collected vs not, SHOW STATS output) are correct. **Loses one point** for the `ANALYZE TABLE` keyword error in the explanation block — a beginner copy-pasting it will get "mismatched input 'TABLE'". The answer self-corrects in the Quick Fix section to the right `ANALYZE iceberg...` form, but the inconsistency is exactly the kind of thing that frustrates a beginner. Also a minor gap on `drop_extended_stats` precondition.

### Beginner clarity: 5 / 5
Strong. Starts by validating the user's intuition ("Yes, Trino knows row counts"), then pivots to *why that's not enough*. Build/probe/broadcast explained in plain English. NDV explained with a concrete tenants/users example. Skew framed with the "80% of events from one customer" example. No unexplained jargon. Excellent pedagogy.

### Practical applicability: 5 / 5
Fits the on-prem k8s + Trino 467 + Iceberg + MinIO stack exactly. Mentions MinIO as the storage location for Puffin. Quick Fix gives concrete next steps: identify hot tables, run ANALYZE on join keys, schedule weekly in the data pipeline. SHOW STATS as a diagnostic step is exactly what a SaaS engineer needs. No incompatible tooling recommended.

### Completeness: 4 / 5
Addresses all four parts of the question:
- Why Trino picks wrong join order (CBO + missing NDV) — covered.
- What statistics actually do — covered.
- Whether you need to do it manually or it happens automatically — covered ("No, not automatic").
- Why a query engine needs separate stats when it knows row counts — covered (post-filter selectivity).

Missing: the `drop_extended_stats` precondition when re-analyzing a subset on a previously-fully-analyzed table. Also doesn't mention that incremental ANALYZE (only analyzing new snapshots) is not really a thing in Trino's Iceberg connector — the user might assume re-running ANALYZE is cheap. Minor.

### Weighted average
(4×2 + 5 + 5 + 4) / 5 = (8 + 5 + 5 + 4) / 5 = **22 / 5 = 4.40**

---

## Pass/fail vs raised threshold
Per-topic threshold for "Trino CBO / ANALYZE TABLE / Puffin statistics / NDV / join ordering" is **4.5** (elevated). Score **4.40** is **below** the 4.5 elevated bar.

**Status**: NEEDS WORK (just below the raised threshold).

The single fix that would push this over the bar is the `ANALYZE TABLE` keyword inconsistency. Once that is fixed everywhere in resources/23-trino-cbo-analyze.md (replace `ANALYZE TABLE foo` with `ANALYZE foo`), the answer would be a clean 4.6+.

---

## Recommended teacher action for next iteration
1. In `resources/23-trino-cbo-analyze.md`, audit every occurrence of `ANALYZE TABLE` and replace with `ANALYZE` (Trino syntax does NOT use the `TABLE` keyword — that's a Spark/Hive-ism). The Iceberg connector docs and `sql/analyze.html` both confirm `ANALYZE table_name [WITH (...)]`.
2. Add a short note about `drop_extended_stats` being required before re-running ANALYZE on a subset of columns if the table was previously analyzed with all columns. This is a real footgun documented in the Trino Iceberg connector page.
3. Optionally clarify the "stale stats vs no stats" point — it's directionally true but worth softening to "stale stats can mislead the CBO worse than no stats in some cases" rather than as an absolute.

---

## Rubric update needed
Add row to score history for topic "Trino CBO / ANALYZE TABLE / Puffin statistics / NDV / join ordering":
- Prior: 0.0 over 0 questions
- This question: 4.40
- New running avg: 4.40 over 1 question
- Status: NEEDS WORK (below 4.5 raised threshold; also only 1 question — needs at least 2 angles before pass)
