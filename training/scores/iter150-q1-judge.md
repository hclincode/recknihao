# Iter 150 Q1 Judge Report — Trino PreparedStatement and Plan Caching

## Overall

- **Weighted score**: 4.20 / 5.00
- **Verdict**: **FAIL** (threshold ≥4.5)

Weighted formula: `(technical_accuracy * 2 + clarity + practical + completeness) / 5`
= `(4 * 2 + 5 + 5 + 4) / 5` = `22 / 5` = **4.4**

Re-checking: `(4*2 + 5 + 5 + 4) / 5 = 22/5 = 4.4` → **FAIL** (just below 4.5).

The answer is *almost* excellent but contains a material factual error about the Trino version that introduced `EXECUTE IMMEDIATE` AND a more serious error about the Trino JDBC driver's default behavior. Both are central to one of the answer's concrete recommendations.

---

## Per-dimension scores

### Technical accuracy — 4 / 5 (weight 2x)

**Correct claims (verified):**
- Trino does NOT cache query plans between EXECUTE calls. Each EXECUTE re-plans from scratch. Confirmed by community discussion and the GitHub issue history; Trino's planning interpretation contaminates the plan tree with session-specific constants which is why generic plan caching is not implemented. ([Trino PREPARE docs](https://trino.io/docs/current/sql/prepare.html), [Issue #1141 discussion of plan caching limits](https://github.com/prestosql/presto/issues/1141))
- `PreparedStatement` with `?` placeholders is supported by the Trino JDBC driver. ([JDBC driver docs](https://trino.io/docs/current/client/jdbc.html))
- SQL injection safety and clean parameter binding are real, valid reasons to use `PreparedStatement`.
- The Postgres-vs-Trino comparison row "Optimize query plan: Every EXECUTE (no plan cache)" is correct.
- The recommendation to keep using `PreparedStatement` for safety even without plan reuse is correct.

**Errors:**

1. **HIGH severity — wrong Trino version for EXECUTE IMMEDIATE.** The answer states: *"the JDBC driver in Trino 467 automatically uses `EXECUTE IMMEDIATE` (available since Trino 425)"*. Verified facts:
   - `EXECUTE IMMEDIATE` was added in **Trino 418** (17 May 2023), not 425. ([Release 418 notes](https://trino.io/docs/current/release/release-418.html))
   - JDBC driver latency improvement to leverage EXECUTE IMMEDIATE was added in **Trino 431** (27 Oct 2023). ([Release 431 notes](https://trino.io/docs/current/release/release-431.html))

2. **HIGH severity — wrong JDBC driver default behavior.** The answer states the JDBC driver "automatically uses EXECUTE IMMEDIATE". This is FALSE. Per the Trino JDBC driver docs, the connection parameter `explicitPrepare` **defaults to `true`**, meaning the driver uses the standard two-step `PREPARE` + `EXECUTE` flow by default. To get the single-call EXECUTE IMMEDIATE optimization, the user must explicitly set `explicitPrepare=false` in the JDBC URL. ([JDBC driver docs — explicitPrepare parameter](https://trino.io/docs/current/client/jdbc.html))

   This is consequential because the engineer asked specifically about reducing per-request overhead. The current answer would lead them to believe they get EXECUTE IMMEDIATE for free on 467, when in reality they need to flip `explicitPrepare=false` to actually collapse the round-trips.

3. **LOW severity — wording on "parse-time win".** The claim "the SQL text itself is parsed once per connection" overstates parse reuse. Trino parses on each EXECUTE for a freshly issued query string. PREPARE/EXECUTE does keep the prepared SQL text server-side but the parse/plan is still re-run at EXECUTE time. Minor — the overall thrust (parse savings are negligible vs planning) is correct.

### Beginner clarity — 5 / 5

- The Postgres-vs-Trino table is excellent and answers the engineer's exact mental-model question directly.
- The walkthrough of what happens on the wire (PREPARE → EXECUTE → re-plan every time) is concrete.
- The "Request 1 ... Request 200" sequence makes the cost concrete.
- The final summary table reinforces the answer cleanly.
- No unexplained jargon; OLAP-specific terms are kept minimal.

### Practical applicability — 5 / 5

- Direct answer to the engineer's two-part question (does it cache? should I use it?).
- Three concrete alternatives offered: materialize the hot path (pre-aggregated Iceberg table, dbt/Spark) — which fits the on-prem Iceberg/Hive Metastore/Trino 467 environment described in `prod_info.md`. Good.
- "Measure before optimizing" with `EXPLAIN ANALYZE` and the 10% rule is the kind of grounded advice the engineer can act on immediately.
- The recommendation to keep `PreparedStatement` is unambiguous.

(Would be a 5 even with the EXECUTE IMMEDIATE error, since the materialization/EXPLAIN advice stands on its own. But note the `explicitPrepare=false` miss is a missed practical lever — a fully complete answer would have told them how to actually turn on the optimization.)

### Completeness — 4 / 5

Covers all four required topics from the question:
- No plan cache: yes
- What PreparedStatement does give: yes
- Alternatives to reduce planning cost: yes
- Recommendation to still use PreparedStatement: yes

Missing:
- The `explicitPrepare=false` JDBC URL parameter, which is the *one concrete lever* the JDBC driver actually exposes for this exact use case. Given that the engineer is asking "what is PreparedStatement actually good for in Trino", omitting the configurable optimization knob is a real gap.
- No mention of session-level options (e.g., adaptive planning settings) or that planning time is often dominated by metastore lookups / partition enumeration, which would be a richer "how to reduce planning latency" answer for a Hive Metastore + Iceberg shop.

---

## Verified-correct claims with sources

| Claim | Source |
|---|---|
| Trino does not cache query plans between EXECUTE invocations | [PREPARE docs](https://trino.io/docs/current/sql/prepare.html), [Plan caching issue #1141](https://github.com/prestosql/presto/issues/1141) |
| EXECUTE IMMEDIATE combines PREPARE+EXECUTE+DEALLOCATE into one statement | [EXECUTE IMMEDIATE docs](https://trino.io/docs/current/sql/execute-immediate.html) |
| EXECUTE IMMEDIATE introduced in Trino 418 (NOT 425) | [Release 418 notes](https://trino.io/docs/current/release/release-418.html) |
| JDBC driver latency improvement via EXECUTE IMMEDIATE added in Trino 431, gated on `explicitPrepare=false` | [Release 431 notes](https://trino.io/docs/current/release/release-431.html), [JDBC docs](https://trino.io/docs/current/client/jdbc.html) |
| Trino JDBC driver supports `?` placeholders via PreparedStatement | [JDBC docs](https://trino.io/docs/current/client/jdbc.html) |

---

## Errors and gaps by severity

**HIGH:**
1. Wrong version attribution: EXECUTE IMMEDIATE is Trino 418, not 425. JDBC driver optimization is Trino 431.
2. Wrong JDBC default: `explicitPrepare` defaults to `true`, so EXECUTE IMMEDIATE is NOT used automatically. User must set `explicitPrepare=false` in the JDBC URL.

**MEDIUM:**
3. Missing the actionable `explicitPrepare=false` JDBC URL parameter — this is the one concrete knob that maps directly to the engineer's stated problem.

**LOW:**
4. Overstates "parse once per connection" — the parse savings claim is loose.
5. Does not mention that for Iceberg + Hive Metastore (the production stack), planning time is often dominated by metastore RPCs and file/partition enumeration; this would be the next logical lever after materialization.

---

## Resource fix recommendations

Update `resources/20-trino-client-patterns.md` (the file the teacher created in iter150) to:

1. **Correct the version numbers.** Replace "available since Trino 425" with "available since Trino 418 (server-side); JDBC driver optimization landed in Trino 431". This must be exact — a SaaS engineer on Trino 467 will accept whatever number the resource says.

2. **Document `explicitPrepare`.** Add a short subsection:
   - Default: `explicitPrepare=true` → driver issues PREPARE + EXECUTE (two HTTP calls).
   - To get the single-call optimization: append `?explicitPrepare=false` to the JDBC URL (Trino server ≥ 431 required).
   - Include the literal JDBC URL example, e.g. `jdbc:trino://coordinator:8443/iceberg?SSL=true&explicitPrepare=false`.
   - Note that this saves an HTTP round-trip per request, but does NOT introduce plan caching.

3. **Reinforce the no-plan-cache fact.** Add a one-line callout: "Even with `explicitPrepare=false`, Trino still re-plans on every EXECUTE. The optimization is purely network round-trip reduction."

4. **Add a "planning latency in Iceberg/HMS environments" note.** For the prod environment (Iceberg + Hive Metastore + Trino 467), call out that metastore latency and file listing dominate planning for partitioned tables, and link to `EXPLAIN (TYPE IO)` and `EXPLAIN ANALYZE VERBOSE` as the diagnostic tools.

5. **Keep the Postgres-vs-Trino comparison table** — it is the highest-value asset in this answer and the weak-ai-responder reproduced it well.

---

## Verdict rationale

The answer's structure, clarity, and core conceptual claim (no plan cache; use PreparedStatement for safety not speed) are strong and would earn a solid pass. But the two HIGH-severity factual errors about EXECUTE IMMEDIATE are exactly the kind of "looks confident, is wrong" output that erodes trust when the engineer goes to write the JDBC URL and finds nothing changes. With the weighted score landing at 4.4, just under the 4.5 pass bar, this iteration's resource needs a targeted correction before the next iteration.
