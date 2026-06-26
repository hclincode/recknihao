# Iter1148 Judge Feedback

**Verdict: 4.0625 PASS NO-OP+WATCH. Q1 surfaces a load-bearing `EXTRACT(YEAR_MONTH FROM date)` parse error (MySQL field imported into a Trino query) — engineer copy-pastes, hits parse failure on first run. Two-level CTE decomposition shape (per-user monthly count → CASE bucket → COUNT per bucket) is otherwise correct. CLASSIFIED RESPONDER SLIP: grep'd resources for `YEAR_MONTH` — ZERO matches; r07/r23/r13 only ever use TRINO-valid EXTRACT fields (YEAR / MONTH / DAY / HOUR / MINUTE / etc.), and r13 §5694 even has an explicit defang `MICROSECOND is NOT a valid Trino EXTRACT field — parse error`. Fabrication is on the Haiku side, not source-anchored. Imported-prior family (same shape as iter925 COUNT(DISTINCT a,b) MySQL slip, iter1006 LIMIT-OFFSET MySQL order slip). NO-OP+watch this iteration; if month-bucketing questions surface YEAR_MONTH again across a future sweep on a different domain → LIGHT FIX-A spec is an additive r07 defang card next to date_trunc('month',ts) canonical naming `EXTRACT(YEAR_MONTH FROM ts)` as a MySQL-only field + parse error in Trino. Q2 (format('%,.2f', amount) for thousands-comma + 2-decimal) is exactly matched by r23 §3.1A line 702 AND quoted verbatim in trino.io/docs/current/functions/conversion.html as the official example — clean STRONG PASS. Q3 (optimize-doesn't-handle-manifests + optimize_manifests is 470+ + Spark rewrite_manifests fallback) is FACTUALLY CORRECT and source-aligned with r17 §13/§24/§185/§209 — verified PR #24678 merged Feb 4 2025 into Trino 470 milestone; minor completeness shave for not naming adjacent native-467 maintenance (expire_snapshots + remove_orphan_files) which is the load-bearing answer for "metadata files piling up after many small-batch inserts". Q4 (sequence → dbt_utils.generate_surrogate_key PRIMARY + ROW_NUMBER FALLBACK) is source-aligned with r27 §1.2 + §4.5A; minor imprecision calling generate_surrogate_key a way to "generate unique integers" when it returns a VARCHAR MD5 hex string (~32 chars). No FIX-A this iter.**

---

## Q1 — Segment users by monthly login count into buckets (<5 low / 5-20 medium / >20 high) + COUNT per bucket. Per-user-monthly first then classify, or one query?

**Question:** Bucket users by monthly login count (<5 low, 5-20 medium, >20 high), then COUNT how many fall in each bucket. One query or staged?

**Responder's answer (summary):**
- One query with two CTEs.
- CTE `monthly_logins`: `SELECT user_id, EXTRACT(YEAR_MONTH FROM login_date) AS year_month, COUNT(*) AS num_logins FROM logins GROUP BY user_id, EXTRACT(YEAR_MONTH FROM login_date)`.
- CTE `bucketed`: `CASE WHEN num_logins < 5 THEN 'low' WHEN num_logins BETWEEN 5 AND 20 THEN 'medium' ELSE 'high' END AS activity_bucket`.
- Final: `SELECT activity_bucket, COUNT(*) FROM bucketed GROUP BY activity_bucket`.

**Critical verification (trino.io/docs/current/functions/datetime.html):**

> Trino 467's EXTRACT function supports ONLY these fields: **YEAR, QUARTER, MONTH, WEEK, DAY, DAY_OF_MONTH, DAY_OF_WEEK, DOW, DAY_OF_YEAR, DOY, YEAR_OF_WEEK, YOW, HOUR, MINUTE, SECOND, TIMEZONE_HOUR, TIMEZONE_MINUTE**.
>
> **`YEAR_MONTH` is NOT in the list. It is a MySQL EXTRACT field (`EXTRACT(YEAR_MONTH FROM dt)` returns YYYYMM as an integer in MySQL).** In Trino 467, `EXTRACT(YEAR_MONTH FROM login_date)` is a **PARSE ERROR**: `mismatched input 'YEAR_MONTH'`.

**Engineer impact.** Copy-paste fails on first run. Two-level shape is sound but load-bearing token is invalid.

**Correct Trino canonical for "per-user per-month bucket":**
```sql
WITH monthly_logins AS (
  SELECT user_id,
         date_trunc('month', login_date) AS month_start,   -- DATE/TIMESTAMP month boundary
         COUNT(*) AS num_logins
  FROM logins
  GROUP BY user_id, date_trunc('month', login_date)
),
bucketed AS (
  SELECT user_id, month_start,
         CASE WHEN num_logins < 5 THEN 'low'
              WHEN num_logins BETWEEN 5 AND 20 THEN 'medium'
              ELSE 'high' END AS activity_bucket
  FROM monthly_logins
)
SELECT activity_bucket, COUNT(*) AS user_months
FROM bucketed
GROUP BY activity_bucket;
```
(If a numeric YYYYMM is specifically needed: `EXTRACT(YEAR FROM login_date) * 100 + EXTRACT(MONTH FROM login_date)` — both valid Trino fields.)

**Source classification.** Grep'd resources for `YEAR_MONTH`/`year_month`: **zero matches**. r07/r23/r13 only use Trino-valid EXTRACT fields. r13 §5167 / §5690 / §5694 even have explicit defangs for MICROSECOND and EPOCH as non-Trino fields. **No resource carries this fabrication.** This is a **one-off responder import from MySQL/Oracle syntax**, consistent with the pinned imported-prior family (iter925 COUNT(DISTINCT a,b), iter1006 `LIMIT n OFFSET m`, iter954 `to_char` mishandling). The two-level CTE shape and the CASE branching are correct; only the EXTRACT field token is wrong.

**Watch label:** r07 EXTRACT-YEAR_MONTH-MySQL-import iter1148. **NO FIX-A this iteration.** If the same fabrication recurs on a different month-bucketing question in a future sweep, escalate to additive r07 defang card adjacent to a `date_trunc('month', ts)` canonical naming `EXTRACT(YEAR_MONTH FROM ts)` as a MySQL-only field that parse-errors in Trino.

**Scores:**
- Technical accuracy: **2.0** — load-bearing parse-error fact (EXTRACT field doesn't exist).
- Beginner clarity: **4.0** — two-CTE walkthrough + CASE branching are explained well.
- Practical applicability: **2.0** — copy-paste fails on first run; engineer must debug the EXTRACT call before anything else works.
- Completeness: **3.5** — "one query yes" + shape decomposition + bucket boundaries (inclusive/exclusive) addressed; only the field-name token is wrong.
- **Avg: 2.875** — FAIL on this question, drags topic but doesn't move it below threshold.

---

## Q2 — Format revenue 1234567.89 → "1,234,567.89" (thousands commas + exactly 2 decimals). Built-in Trino or manual?

**Question:** Format `1234567.89` to `"1,234,567.89"` string. Built-in Trino way or manual string-piecing?

**Responder's answer (summary):**
- `format('%,.2f', amount)` — printf/Java Formatter style.
- `%,` = thousands grouping, `.2f` = 2 decimals.
- Returns VARCHAR.
- Cites r23 §3.1A.

**Critical verification (trino.io/docs/current/functions/conversion.html, official docs):**

> Quoted example: `SELECT format('%,.2f', 1234567.89); -- '1,234,567.89'`

Exact match. r23 §3.1A line 702 has the same example. r23 §3.1A also explicitly states accepts BIGINT/DOUBLE/DECIMAL directly via `%d`/`%.2f`/`%,d` with no explicit CAST needed (verified at line 884).

**Scores:**
- Technical accuracy: **5.0** — official docs literally use this exact example.
- Beginner clarity: **5.0** — names the printf/Java Formatter analogy + decodes `%,` and `.2f`.
- Practical applicability: **5.0** — copy-paste works.
- Completeness: **5.0** — names return type, names alternative (CAST + concat) is implicit, no over-padding.
- **Avg: 5.0**

---

## Q3 — Many small-batch inserts/day; already run EXECUTE optimize for small DATA files. Does optimize handle MANIFEST/metadata files, or separate command?

**Question:** Frequent inserts → already optimizing data files. Does optimize also handle manifests/metadata, or separate?

**Responder's answer (summary):**
- `optimize` rewrites DATA files only, NOT manifests.
- Manifest rewriting via `ALTER TABLE ... EXECUTE optimize_manifests` is Trino **470+** (your prod is 467 — not available).
- For Trino 467: use Spark `CALL iceberg.system.rewrite_manifests(table => '...')`.
- Frames manifest rewriting as secondary/nice-to-have.
- Cites r17.

**Critical verification (trino.io/docs/467/connector/iceberg.html + GitHub PR history):**

> Trino 467 Iceberg connector ALTER TABLE EXECUTE procedures: **only** `optimize`, `expire_snapshots`, `remove_orphan_files`, `drop_extended_stats`. **`optimize_manifests` is NOT listed.**
>
> `optimize_manifests` was added in [PR #24678](https://github.com/trinodb/trino/pull/24678), merged Feb 4 2025, added to the **Trino 470 milestone** (follow-up [PR #25378](https://github.com/trinodb/trino/pull/25378) extends it to per-top-level-partition). Trino 478 release notes (29 Oct 2025) include a fix for `optimize_manifests` on tables without a snapshot — confirming it's been in 470+ since.

All three of the responder's load-bearing claims are CORRECT:
1. `optimize` rewrites data files only → CORRECT (matches r17 §17-19 + iceberg.html docs).
2. `optimize_manifests` is 470+ not 467 → CORRECT (PR #24678 → milestone 470).
3. Spark `CALL iceberg.system.rewrite_manifests` is the Trino-467 fallback → CORRECT (matches r17 §24 + §185 + §229).

**Completeness shave.** For "metadata files piling up after many small-batch inserts/day", the load-bearing native-467 maintenance procedures are `expire_snapshots` (drops old snapshot pointers — their referenced manifests/manifest-lists become eligible for GC) and `remove_orphan_files` (physical GC of files no longer referenced by any live snapshot). Both ARE in Trino 467 natively (`ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')`). Most "metadata bloat after many inserts" symptoms are *snapshot accumulation* not *manifest fragmentation* — so the engineer's actual operational problem is largely solvable WITHOUT Spark. The responder framed manifest rewriting as the only metadata-side maintenance and routed to Spark; the more complete framing is:
- Native-467 weekly: `expire_snapshots` + `remove_orphan_files` (covers 80% of metadata-bloat symptoms)
- Plus weekly Spark `rewrite_manifests` (for true manifest-fragmentation, the remaining 20%; native `optimize_manifests` waits for 470+).

r17 §13 actually lists all four as core procedures, so this is a recall-ceiling shave, not a resource gap.

**Source classification.** All version-specific facts are correct and source-aligned. NO RESOURCE DEFECT. NO FIX-A.

**Scores:**
- Technical accuracy: **4.5** — version claim 470+ verified, Spark CALL form verified, optimize-data-only verified.
- Beginner clarity: **4.5** — clean separation of data files vs manifests; "your version is 467 so..." routing is direct.
- Practical applicability: **4.0** — gives Spark fallback (works on this on-prem stack; Spark IS in the production stack per prod_info.md). Could route to native `expire_snapshots`/`remove_orphan_files` first as the easier-to-deploy answer.
- Completeness: **4.0** — answered manifest question precisely; missed the adjacent native-467 metadata maintenance (`expire_snapshots`/`remove_orphan_files`) which is the load-bearing answer for the engineer's actual problem of metadata bloat from frequent inserts.
- **Avg: 4.25** — PASS

---

## Q4 — Oracle SEQUENCE NEXTVAL for integer PKs migrating to Trino (no sequences). Standard for unique numeric surrogate keys in dbt/Trino?

**Question:** Oracle dim loads used `seq.NEXTVAL` for integer PKs. Trino has no sequences. Standard for unique numeric surrogate keys in dbt/Trino?

**Responder's answer (summary):**
- Trino has no persistent sequences.
- **Option 1 (recommended)**: `dbt_utils.generate_surrogate_key(['col1','col2'])` — deterministic MD5 hash, idempotent across runs, good for dim→fact joins + SCD-2.
- **Option 2**: `ROW_NUMBER() OVER (ORDER BY ...)` — stable only within a single run, throwaway/one-time loads only.
- Contrast table.
- Calls both methods "a way to generate unique integers".
- Cites r27 §1.2 + §4.5A.

**Critical verification:**

> r27 §4.5A (lines 1773-1778) explicitly:
> - PRIMARY: `dbt_utils.generate_surrogate_key([col_list])` — output type **VARCHAR (MD5 hex string, ~32 chars)** — idempotent across runs AND clusters.
> - FALLBACK: `ROW_NUMBER() OVER (ORDER BY ...)` — output type **BIGINT** — stable only within a single full-refresh run.
> - BANNED: Iceberg `GENERATED ALWAYS AS IDENTITY` (does not exist).
>
> r27 §4.5D row at line 2083: "If you need a BIGINT surrogate, use `ROW_NUMBER() OVER (ORDER BY ...)` (only stable within a single run) or pre-allocate the BIGINT in the source system. For stable string surrogates, use `generate_surrogate_key`."

The responder's primary/fallback ranking + idempotency framing + use-case routing all match r27.

**Imprecision.** Engineer specifically asked for "unique NUMERIC surrogate keys". Responder labels both methods as "a way to generate unique integers". `generate_surrogate_key` returns **VARCHAR**, not integer — r27 §4.5A line 1776 is explicit on this. The body of the responder's answer does say "MD5 hash" so the reader can infer it's a string, but the headline framing is muddled. The canonical migration framing the engineer needs is:

> "On dbt-trino, the standard pattern is to **abandon the strict numeric-PK requirement** and accept a deterministic VARCHAR MD5 hash via `dbt_utils.generate_surrogate_key`. The hash is reproducible across runs/clusters, so SCD-2 and incremental MERGE work cleanly. If a true BIGINT PK is genuinely required (downstream system constraint), `ROW_NUMBER() OVER (ORDER BY ...)` gives you BIGINT but is only stable within a single full-refresh run — re-running can re-map keys."

Responder conveys ~80% of this; the missing piece is the explicit "abandon-the-numeric-requirement" framing + the VARCHAR type call-out on Option 1.

**Source classification.** All facts are source-aligned with r27. Mislabel of "unique integers" is a responder slip, not a resource defect. r27 §4.5A and §4.5D are crystal-clear that generate_surrogate_key returns VARCHAR. NO RESOURCE FIX. NO FIX-A.

**Scores:**
- Technical accuracy: **4.0** — calls VARCHAR-returning function an "integer generator"; otherwise correct.
- Beginner clarity: **4.5** — primary/fallback contrast table is clear, idempotency framing is helpful.
- Practical applicability: **4.0** — engineer arrives at right action (use generate_surrogate_key as default) but the "numeric" framing is muddled.
- Completeness: **4.0** — names primary, fallback, banned form (Iceberg IDENTITY implicit via the recommendation); doesn't explicitly call out "VARCHAR return type, not integer" and doesn't frame "abandon strict numeric-PK requirement" crisply.
- **Avg: 4.125** — PASS

---

## Overall verdict

**Iter1148: 4.0625 PASS NO-OP+WATCH**

| Q | Score | Topic | Status |
|---|---|---|---|
| Q1 | 2.875 | Analytical query patterns on Iceberg+Trino | FAIL (responder slip) |
| Q2 | 5.000 | SQL query best practices for OLAP | STRONG PASS |
| Q3 | 4.250 | Iceberg table maintenance | PASS (minor completeness shave) |
| Q4 | 4.125 | Oracle PL/SQL→dbt/Trino migration | PASS (minor imprecision) |

**FIX-A spec (DO NOT WRITE — watch only):**
- None this iteration. Q1 fabrication is responder-only (zero resource matches for YEAR_MONTH). Imported-prior family slip consistent with pinned `feedback_synthesis_ceiling_stop_churning` + the imported-priors recurrence pattern.

**Watch labels for next sweep:**
- r07 EXTRACT-YEAR_MONTH-MySQL-import — re-probe with a different month-bucket question (e.g., "sum revenue per calendar month", "cohort by signup month") to confirm one-off vs recurrent. If recurrent → additive r07 defang card naming YEAR_MONTH as MySQL-only + canonical `date_trunc('month', ts)` redirect.
- r17 expire_snapshots+remove_orphan_files routing on "metadata bloat from frequent inserts" — re-probe with a question phrased around "metadata files filling up" / "snapshot accumulation" to confirm whether the responder leads with native-467 procedures vs Spark when the engineer's actual problem is snapshot accumulation not manifest fragmentation.

**Production-environment fit:** All four answers fit the on-prem Trino 467 + Spark + Iceberg 1.5.2 + HMS + MinIO stack described in `prod_info.md`. Q3's Spark-fallback advice is viable because Spark is in the on-prem stack for ingestion. Q4's dbt-trino guidance is correct for the dbt-trino transformation layer. Q1's parse error is independent of the stack.

**Margin status across all touched topics (post-update):**
- Analytical query patterns on Iceberg+Trino: was 4.59967/100, after Q1=2.875 → ~4.583/101 — margin +1.083 above threshold (still healthy, the fail doesn't move topic anywhere near threshold).
- SQL query best practices: was 4.56524/213, after Q2=5.0 → ~4.566/214 — clean lift.
- Iceberg table maintenance: was 4.4824/182, after Q3=4.25 → ~4.481/183 — flat.
- Oracle PL/SQL migration: was 4.4454/120, after Q4=4.125 → ~4.4428/121 — flat.

All topics remain comfortably above the 3.5 pass threshold (and well above the +0.9 historical margins for the at-risk rows). No structural risk.

---

## Doc citations

- [Trino 467 Date/time functions — EXTRACT field list](https://trino.io/docs/current/functions/datetime.html) — confirms YEAR_MONTH is NOT a valid Trino EXTRACT field.
- [Trino 467 Iceberg connector — ALTER TABLE EXECUTE procedures](https://trino.io/docs/467/connector/iceberg.html) — confirms only `optimize`, `expire_snapshots`, `remove_orphan_files`, `drop_extended_stats` are listed in 467.
- [Trino PR #24678 — Add optimize_manifests table procedure to Iceberg](https://github.com/trinodb/trino/pull/24678) — merged Feb 4 2025, milestoned 470.
- [Trino PR #25378 — Optimize manifests per top-level partition (follow-up)](https://github.com/trinodb/trino/pull/25378) — confirms #24678 is the original.
- [Trino conversion functions — format()](https://trino.io/docs/current/functions/conversion.html) — confirms `SELECT format('%,.2f', 1234567.89); -- '1,234,567.89'` is the documented example.
- r07 §1.2 (procedural-construct map), r17 §13/§24/§185/§209, r23 §3.1A line 702, r27 §1.2/§4.5A/§4.5D — all source-aligned with responder claims (except Q1 YEAR_MONTH which is responder-side fabrication, NOT in any resource).
