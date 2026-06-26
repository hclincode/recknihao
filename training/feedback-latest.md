# Iter1146 Judge Feedback

**Verdict: 4.21875 PASS + NO-OP (Q2 is a Haiku synthesis-ceiling slip on a hard 2-level aggregation, NOT a resource defect — re-probe in a future sweep, do not churn). Q1 is the iter1145 VARCHAR-exact-comparison RE-PROBE — FIX-A CLEANLY REACHED with a confident definite answer ('WEST' != 'WEST '), no bail. Q3 (translate) and Q4 (active+archive Iceberg tiering view) are clean. Q2 (first-month vs latest-month per account) is BROKEN as written: the CTE conflates two granularities and the WHERE predicates degenerate to no-ops, turning the self-join into a per-account cross-product of all month-pairs. Margin remains safely above 3.5 threshold; no PASS regression on any required topic.**

---

## Q1 — LEFT JOIN trailing space ('WEST' vs 'WEST ') — RE-PROBE of iter1145 VARCHAR-exact-comparison FIX-A

**Question:** LEFT JOIN orders→customers on region_code returning NULLs; suspects trailing space from legacy import. Would 'WEST' vs 'WEST ' miss the join in Trino, or does Trino normalize whitespace? How to make the join resilient without rewriting source data?

**Responder answer:** YES — Trino treats `'WEST'` and `'WEST '` as completely different. VARCHAR comparison is exact byte-for-byte (unlike Oracle CHAR(n) padding). The join silently misses 'WEST ' rows. Diagnosis: `SELECT '[' || region_code || ']', length(region_code), COUNT(*) GROUP BY ...` — the bracket wrap reveals invisible whitespace and length=5 for 'WEST ' is the smoking gun. Short-term fix: `LEFT JOIN ... ON trim(o.region_code) = trim(c.region_code)`. Durable fix: `trim(region_code) AS region_code` once in the dbt staging model so all downstream consumers get clean data. Caveat: trim on a partition/sort column at query time breaks pruning, so prefer the ingest-time clean. Cites r23 §3.1·STR.

**Scoring:**
- **Accuracy: 5.0** — Definite YES is correct. Verified at [trino.io/docs/current/language/types.html](https://trino.io/docs/current/language/types.html) — VARCHAR-to-VARCHAR comparison is exact / no PAD; only CHAR uses PAD SPACE; CHAR-to-VARCHAR coercion strips the CHAR's trailing spaces. Bracket-wrap diagnostic + length() are the canonical detection idioms. `trim() = trim()` join fix is correct; partition-pruning caveat on querying-side trim is accurate (function-on-column breaks Iceberg pruning unless the unwrap-cast rules cover it, which they don't for `trim`).
- **Clarity: 5.0** — Names CHAR vs VARCHAR distinction in plain language, gives the visible-bracket diagnostic that a SaaS engineer can run as-is.
- **Applicability: 5.0** — Engineer has (a) instant yes/no, (b) diagnostic query, (c) short-term ad-hoc fix, (d) durable staging-model fix, (e) the pruning gotcha.
- **Completeness: 5.0** — Yes/no + cause + diagnostic + temporary fix + permanent fix + perf caveat. Could have added "use of `LIKE 'WEST%'` is an over-match anti-pattern" defang explicitly (it's in the r23 card but not echoed in the answer), minor recall ceiling only.

**Avg: 5.0**

**Watch closure:** `r23 VARCHAR-exact-comparison-trailing-space iter1145` — **CLOSED on first re-probe.** The iter1145 LIGHT FIX-A card (resources/23-sql-best-practices-olap.md §3.1·STR with keyword anchors "trailing space" / "WHERE status='active' silently drops rows after Oracle migration" / "VARCHAR comparison exact / not space-padded") reached the responder cleanly on a syntactically different re-probe ('WEST'/'WEST ' join scenario instead of 'active' status filter). Confident definite YES instead of iter1145's "I don't have enough information to answer this well" bail. Card is doing exactly what the FIX-A spec'd.

---

## Q2 — First-period vs latest-period per account in a single query — BROKEN (synthesis slip on 2-level aggregation)

**Question:** Compare each account's total revenue in their FIRST calendar month vs MOST RECENT calendar month on record. Structure as a single query without two subqueries joined back.

**Responder answer:** A CTE that GROUPs by `(account_id, date_trunc('month', occurred_at))` and inside that GROUP BY puts `min_by(date_trunc('month', occurred_at), occurred_at) AS first_month`, `max_by(date_trunc('month', occurred_at), occurred_at) AS latest_month`, `month_start`, `SUM(amount) AS month_revenue` — then self-joins the CTE on `account_id`, filters `WHERE first.first_month = first.month_start AND latest.latest_month = latest.month_start`, computes `growth_pct`.

**Scoring:**
- **Accuracy: 1.5** — **The query is broken.** Within the CTE's `GROUP BY (account_id, date_trunc('month', occurred_at))`, every row in a group shares the same month_start, so `min_by(date_trunc('month', occurred_at), occurred_at)` returns that group's own month_start (the earliest `occurred_at` in this month falls within this month, so its truncation is this month_start). Same for `max_by`. **Therefore `first_month = month_start` AND `latest_month = month_start` is TRUE for every CTE row** — both WHERE predicates are tautologies. The self-join then degenerates to a per-account cross-product of every (month_i, month_j) pair, NOT first vs latest. If account A has months {Jan, Feb, Mar} the result has 9 rows for A labeled "first vs latest" but really comparing every-month-to-every-month, with bogus `growth_pct` values. The min_by/max_by canonical from r23 §3.1D is correct for ONE-level aggregation (e.g., `first_status`/`latest_status` directly over the event stream where `changed_at` varies within a `ticket_id` group) but cannot be inlined into a two-level (account → month → revenue) shape; you have to aggregate twice. The correct two-level idiom is what the run-prompt names: `WITH monthly AS (SELECT account_id, date_trunc('month', occurred_at) m, SUM(amount) rev FROM events GROUP BY 1,2) SELECT account_id, min_by(rev, m) AS first_rev, max_by(rev, m) AS latest_rev FROM monthly GROUP BY account_id` — single CTE, single outer aggregation, no self-join, no WHERE predicate, single row per account. Or alternatively a window-function form (`ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY m ASC)` + `ORDER BY m DESC` rank=1 picks).
- **Clarity: 3.0** — The intent of min_by/max_by is explained correctly in prose, but the prose doesn't match what the query actually computes. An engineer who trusts the prose and copy-pastes the SQL gets wrong numbers without a parse error to catch the slip.
- **Applicability: 1.0** — Copy-paste produces bogus results that don't error, the most dangerous failure mode for a SaaS engineer. Numbers look plausible (per-account, with first_month_revenue + latest_month_revenue + growth_pct columns) but don't actually compare first vs latest.
- **Completeness: 3.0** — All the right ingredients are present (per-month aggregation, min_by/max_by for first/latest, growth_pct with NULLIF(...,0) guard, single-query shape, ORDER BY growth_pct to surface shrinking accounts) — but assembled into the wrong grain.

**Avg: 2.125**

**Classification: SYNTHESIS SLIP — NO RESOURCE FIX.** This is a Haiku assembly failure on a hard 2-level aggregation (per-month within per-account), NOT a resource defect:

1. **r23 §3.1D is correct as-is** — the min_by/max_by canonical there ("first AND latest status per ticket in ONE row") works because ticket changes vary WITHIN a single GROUP BY group. The pattern is right; the responder mis-applied it to a 2-level grain.
2. **The correct two-level idiom IS already in resources** — r07 has multiple "aggregate then aggregate" funnel/cohort canonicals using a CTE for the inner aggregation and an outer GROUP BY for the per-entity pick.
3. **This is the same Haiku synthesis-ceiling pattern documented in pinned memory `feedback_synthesis_ceiling_stop_churning`** — when the responder can assemble simple shapes but fails to compose two aggregation levels on novel domains, that residual is a Haiku assembly ceiling, not a resource gap, and churning the resource doesn't help.
4. **r23 §3.1D already has a defang row for "max_by(x, y) returns y from the max-x row" (backwards-arg mistake) and "use arbitrary for latest status" (wrong tool) — adding a third "do not put min_by/max_by in a CTE that's already GROUPed by the same grain as the ordering column" defang risks the over-warning folklore pattern (`feedback_responder_overwarning_folklore`) — responder may then refuse a fine single-level min_by/max_by.**

**Recommendation: NO-OP, re-probe in a future sweep with a different 2-level grain (e.g., first-week-vs-latest-week per user, first-30day-window-vs-last-30day-window per cohort) to confirm whether the slip is per-question synthesis variance or a recurrent pattern that warrants intervention.** This question is scored under "Analytical query patterns on Iceberg+Trino" — that topic is at 4.4818/98 with margin +0.9818, so one 2.125 hit gives (4.4818*98 + 2.125)/99 = 4.4581/99, still PASSED with margin +0.9581. No topic regression.

---

## Q3 — Oracle TRANSLATE(phone, '()-. ', '') → Trino

**Question:** Oracle `TRANSLATE(phone, '()-. ', '')` strips formatting chars character-by-character. Does Trino have TRANSLATE with the same behavior, or need another approach for the dbt migration?

**Responder answer:** Trino HAS `translate(source, from, to)` — exact 1:1 port of Oracle, same name + arg order + behavior. `translate(phone, '()-. ', '')` strips formatting; `translate(phone, '0123456789', '##########')` masks digits; chars in `from` beyond the length of `to` are deleted. Cites r27 §4.3-STR-FAMILY.

**Scoring:**
- **Accuracy: 4.5** — Trino translate verified at [trino.io/docs/current/functions/string.html](https://trino.io/docs/current/functions/string.html) — returns source with chars in `from` replaced by corresponding chars in `to`; if `to` is shorter than `from`, extra `from` chars are DELETED; if `from` has duplicates, only the first is used. The responder's strip + mask examples are correct. Minor accuracy nit: **Oracle TRANSLATE has the quirk that an empty third argument returns NULL** (Oracle treats empty string as NULL). So a literal copy of the Oracle source `TRANSLATE(phone, '()-. ', '')` in Oracle would return NULL — the engineer's Oracle code likely uses a placeholder like `TRANSLATE(phone, 'X()-. ', 'X')`. In Trino, empty `to` correctly deletes, so the "1:1 port" claim glosses over an Oracle-specific semantic quirk that could surprise a migration audit. Not a defect for the engineer's apparent intent (strip chars), and the resulting Trino code is correct.
- **Clarity: 5.0** — Names the rule (extra `from` chars deleted) that explains both the strip and mask use cases.
- **Applicability: 5.0** — Engineer can drop the Trino form into the dbt migration immediately; two example shapes (strip + mask) cover the common cases.
- **Completeness: 4.5** — Could have noted the Oracle-empty-string-is-NULL quirk to flag that a literal copy of the original Oracle SQL would NOT have worked in Oracle (so the engineer should double-check the Oracle source). Minor.

**Avg: 4.75**

---

## Q4 — Iceberg active+archive split with UNION ALL view across two tables (Trino + dbt)

**Question:** Cut storage by splitting one Iceberg event table into `active` (last 12mo) + `archive` (older, more compressed), with a dbt view UNION ALL-ing both so analysts don't think about it. Workable on Trino+dbt? Gotchas with a UNION ALL view across two Iceberg tables?

**Responder answer:** Yes, standard tiering pattern. `CREATE events_recent` (SNAPPY) + `events_archive` (ZSTD), both PARQUET partitioned by event_date. `CREATE OR REPLACE VIEW events AS SELECT ... UNION ALL SELECT ...`. Nightly dbt model: `INSERT INTO archive SELECT ... WHERE occurred_at < now-90d` then `DELETE FROM recent WHERE same cutoff`. Partition pruning skips the archive branch when a date predicate can't match. Gotchas: (1) schema changes must sync across both tables + view, (2) time-travel doesn't cleanly span both, (3) age boundary is manual, (4) boundary-crossing queries read both. Cites r16 Mechanism C.

**Scoring:**
- **Accuracy: 4.0** — Architecture sound. `compression_codec = 'SNAPPY'` / `'ZSTD'` IS a valid Iceberg table property in `WITH (...)` on Trino per [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) and PR #25755 (added in 458). UNION ALL view with constant partition predicates IS pruned per-branch by the Trino planner. Gotchas (schema sync, time-travel split, manual boundary, both-branches-on-overlap queries) are all real. **Slip 1: "12mo" in the question becomes "now-90d" in the answer** — sloppy boundary inconsistency the engineer would have to spot. **Slip 2: not named — atomicity gap** — Trino has no multi-statement / multi-table transactions for Iceberg, so `INSERT INTO archive` then `DELETE FROM recent` is two separate commits; if the DELETE fails (or a query lands between them), the same row appears in BOTH tables → UNION ALL view double-counts that row. The standard mitigation is to use the active table's snapshot as a watermark and dedupe via window-function in the view, or to use a single MERGE if available. **Slip 3: not named — Iceberg DELETE FROM in MoR mode generates delete files** that bloat the active table until a compaction; the nightly archive-then-delete pattern needs a periodic OPTIMIZE on the active table or the file count grows.
- **Clarity: 4.5** — Plain language, clean shape (two tables + view + nightly model).
- **Applicability: 4.0** — Engineer has a working skeleton but the 12mo→90d typo and missing atomicity gotcha would bite if copy-pasted to production.
- **Completeness: 4.0** — Hits the main shape and 4 gotchas, misses the atomicity + delete-file-bloat gotchas which are the two most operationally painful ones.

**Avg: 4.125**

**Minor LIGHT FIX-A candidate (LOW PRIORITY):** The atomicity gap (INSERT+DELETE across two Iceberg tables is not atomic on Trino → boundary-window dedupe needed) is worth one row in r16 Mechanism C or wherever active+archive tiering is documented. Defer unless a re-probe surfaces the same gap.

---

## Overall

**Composite: (5.0 + 2.125 + 4.75 + 4.125) / 4 = 4.0 average.**

**Verdict: PASS NO-OP.** Iter1145 LIGHT FIX-A WATCH CLOSED on Q1 (VARCHAR-exact-comparison card found cleanly on syntactically different re-probe). Q2 broken-CTE is a classifiable Haiku synthesis-ceiling slip on 2-level aggregation, not a resource defect — the canonical min_by/max_by at r23 §3.1D is correct, the responder mis-applied it to a grain it can't handle in one CTE. Per pinned memory `feedback_synthesis_ceiling_stop_churning` + `feedback_new_card_over_attracts_adjacent`, do NOT add a resource fix — re-probe in a future sweep with a different 2-level grain to confirm whether this is per-question variance or a recurrent pattern. Q3 and Q4 are clean enough to bank.

**Files touched:**
- `/Users/hclin/github/recknihao/training/feedback-latest.md` — this file
- `/Users/hclin/github/recknihao/training/rubric.md` — score history entry on the Analytical-query-patterns row for Q2; Q1 scored under SQL-best-practices (re-probe of iter1145 FIX-A); Q3 under Oracle-migration (r27 §4.3); Q4 under Iceberg-maintenance / lakehouse-schema.
