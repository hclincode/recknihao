# Iter 208 Q1 — Judge Feedback

## Topic
Trino federation / cross-source connectors (broadcast vs partitioned join across Postgres + Iceberg)

## Scores

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 3.0 | Names the wrong tunable threshold property; one structural mistake about AUTOMATIC fallback; minor mistake on EXPLAIN render. |
| Beginner clarity | 4.5 | Excellent: defines broadcast vs partitioned plainly, walks through the build-vs-probe concept, ties everything back to the user's 300K-row tenants table. |
| Practical applicability | 3.0 | Engineer is asked "is there a threshold I can tune?" — answer names the wrong property. Practical actions (SET SESSION, SHOW STATS, EXPLAIN ANALYZE) are correct, but the central tuning knob is misidentified. |
| Completeness | 4.0 | Covers strategy difference, decision mechanism, what changes when crossed, how to verify, and how to tune. Missing: the actual `join_max_broadcast_table_size` knob (100MB default), and a clear statement that AUTOMATIC without stats defaults to hash-distributed (PARTITIONED). |

**Average: (3.0 + 4.5 + 3.0 + 4.0) / 4 = 3.625**

## Verdict
**FAIL** — Topic pass threshold for Trino federation is **4.5** (raised threshold per the rubric override). 3.625 is well below that.

---

## What was correct and verified

- `join_distribution_type` is the correct session property name (underscore). Confirmed on trino.io.
- Three valid values: `AUTOMATIC` (default), `BROADCAST`, `PARTITIONED`. Verified.
- `SET SESSION join_distribution_type = 'BROADCAST'` syntax is correct. Verified.
- `SHOW STATS FOR app_pg.public.tenants` is the correct way to inspect stats. Verified.
- The PostgreSQL connector relies on stats produced by native Postgres `ANALYZE` (via `pg_stats`) — verified on the PostgreSQL connector page.
- `ANALYZE iceberg.analytics.events WITH (columns = ARRAY['tenant_id','occurred_at'])` is real, valid Iceberg-connector ANALYZE syntax. Verified on the Iceberg connector page.
- No crash when the broadcast threshold is crossed — Trino transparently re-plans to partitioned. Verified.
- Conceptual description of broadcast vs partitioned join (build side replicated to every worker vs both sides hash-shuffled) is accurate.
- Predicate pushdown advice (filtering on the Postgres side) is correct and relevant.
- Trino 467 reference is appropriate for the production stack.

---

## What was missing or wrong

### 1. CRITICAL — Wrong threshold property named (Technical accuracy & Practical applicability)
The answer states:

> "On Trino 467, the key property is `query.max-memory-per-node` (defaults to ~20% of worker JVM heap). Broadcast happens when the CBO's estimate fits within that budget."

This is wrong. The actual threshold that bounds broadcast eligibility under `AUTOMATIC` is:
- **Session property:** `join_max_broadcast_table_size`
- **Config property:** `join-max-broadcast-table-size`
- **Default:** **100 MB**

`query.max-memory-per-node` is a generic per-query memory cap that applies to all operators, not the broadcast eligibility threshold. The engineer literally asked "Is there a row count or size threshold I can tune?" — and the answer gives the wrong tunable. This is the single biggest defect of the answer.

For the user's tenant table (~300K rows × ~200 bytes ≈ 60 MB), the table is still under the 100 MB default, so broadcast is still chosen. Once it crosses 100 MB (or whatever the cluster has tuned this property to), AUTOMATIC will switch to PARTITIONED. That's the threshold story the engineer needed.

### 2. AUTOMATIC fallback when no stats are available
The answer says: "If Trino has no statistics about your tenants table, it falls back to heuristics and often guesses wrong — it may pick partitioned even when broadcast would be dramatically faster."

Per official docs: when no cost can be computed, AUTOMATIC **defaults to hash distributed (PARTITIONED) joins**. The directional conclusion (you get partitioned when you'd want broadcast) is right, but calling it "heuristics" is misleading — there is a documented deterministic fallback. A precise rewrite would say: "Without stats, AUTOMATIC has no cost estimate, so it falls back to hash-distributed (PARTITIONED) joins regardless of actual table size."

### 3. EXPLAIN output labels
The answer tells the engineer to look for `Join[BROADCAST]` or `Join[PARTITIONED]` in `EXPLAIN ANALYZE`. In actual Trino plans, you typically see `Distribution: REPLICATED` (for broadcast) and `Distribution: PARTITIONED` on the join node, or `BROADCAST` as a fragment type label. The `Join[BROADCAST]` syntax is not what the engineer will literally see in output, which will confuse them when they run it.

### 4. Missing knobs that are directly relevant
- `join_max_broadcast_table_size` (the actual tuning lever — biggest gap).
- `dynamic-filtering` / dynamic filters — directly relevant to "cross-catalog join is getting slower" because dynamic filtering can dramatically reduce the Iceberg-side scan when joining with Postgres. Worth at least a sentence pointing to it.
- No mention of `join_reordering_strategy` (defaults to `AUTOMATIC`) — relevant when explaining how the CBO chooses a plan.

### 5. Production-fit nits
- The answer reasonably defers to Trino's default behavior, but does not call out the 100 MB default as the actual operative threshold for this question. On Trino 467 (the production version), this default still applies.
- Worth noting that for cross-catalog joins the build side is normally the Postgres side (it has no stats unless `ANALYZE` was run on Postgres), so stats hygiene on the Postgres side is the most leveraged action.

---

## Specific resource fixes the teacher should make

1. **Add an explicit section on `join_max_broadcast_table_size`** to the Trino federation / join strategy resource(s):
   - Name the session property and config property.
   - State the 100 MB default.
   - Explain that this — not `query.max-memory-per-node` — is the threshold the CBO compares the estimated build side against when `AUTOMATIC` is in effect.
   - Show how to inspect (`SHOW SESSION LIKE 'join_max_broadcast_table_size'`) and how to tune it (per query via `SET SESSION`, cluster-wide via `config.properties`).

2. **Correct the description of AUTOMATIC fallback when stats are missing.** State plainly: "Without table statistics, AUTOMATIC cannot compute a cost and defaults to hash-distributed (PARTITIONED) joins. This is one of the most common reasons a join you expect to be broadcast turns out partitioned."

3. **Fix the EXPLAIN output guidance.** Resources should show the literal labels the engineer will see: `Distribution: REPLICATED` (broadcast) vs `Distribution: PARTITIONED`, ideally with a small EXPLAIN snippet. Drop the made-up `Join[BROADCAST]` / `Join[PARTITIONED]` notation.

4. **Add a short subsection on dynamic filtering for cross-catalog joins.** When the dimension table is in Postgres and the fact is in Iceberg, dynamic filters built from the Postgres side can prune Iceberg files and row groups dramatically — a frequent "free win" once `tenants` grows beyond simple broadcast.

5. **Add explicit "stats hygiene checklist" for cross-catalog joins** that covers both sides:
   - Postgres side: native `ANALYZE` on Postgres; verify with `SHOW STATS FOR pg_catalog.table`.
   - Iceberg side: `ANALYZE iceberg.schema.table WITH (columns = ARRAY[...])` on join keys and predicate keys; show how Puffin/NDV stats interact with AUTOMATIC.

These fixes target the recurring weak spot for this topic: the answers describe broadcast vs partitioned conceptually but miss the actual operative tunable threshold, which is the question SaaS engineers most frequently ask.
