# Judge Feedback — Iter 349 Q1

**Date**: 2026-05-28
**Phase**: extended
**Topic**: Multi-tenant analytics — Trino resource group selector regex semantics (svc_ prefix re-probe of iter348 failure)
**Result**: **FAIL** (3.25 / 5.00)

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 2.0 | Central explanation of regex matching is factually wrong. Answer says "your pattern `svc_` does technically match `svc_billing` as a substring" — this is false. Trino uses `Matcher.matches()` (full-string), verified against Trino source (StaticSelector) and official docs. `svc_` (no metacharacters) matches ONLY the literal 4-character string `svc_`. The fix (`svc_.*`) is correct, but the diagnosis sends the user down the wrong path. |
| Beginner clarity | 4.0 | Structure is clean: problem statement, fix, breakdown of `.*`, ordering rule. Easy to read, well-formatted. Loses 1.0 only because the false "substring match" claim plants a wrong mental model that the engineer will carry forward to other selectors. |
| Practical applicability | 3.5 | The recommended JSON snippet (`"user": "svc_.*"`) will work, so the engineer can ship a fix. But the answer's two "actual issue" theories — (a) "you're hitting a different selector first" and (b) "you have a typo" — actively misdirect debugging. The engineer might reorder selectors thinking THAT was the problem, when in reality the missing `.*` was the issue. Also missed: production stack uses JWT auth, so the `user` field equals the JWT subject claim — worth noting. |
| Completeness | 3.5 | Covers fix and ordering. Misses (a) the actual mechanism (matches() vs find() / full-string vs substring), (b) verification recipe (`SELECT user, resource_group_id FROM system.runtime.queries`), (c) JWT-to-username mapping on this production stack. |
| **Average** | **3.25** | **FAIL** (< 4.0) |

---

## Critical issue: this is the iter348 bug, repeated

The iter348 Q1 failure was: responder said Trino selectors use `Matcher.find()` (substring match) when they actually use `Matcher.matches()` (full-string). Teacher fixed resources/05 in iter348 and resources/22 in iter349. Yet **this answer says the same wrong thing**:

> "The default regex matching in Java (like most languages) looks for a substring match"
> "your pattern `svc_` does technically match `svc_billing` as a substring"

This is the bug. Trino's StaticSelector calls `userMatcher.matches()`, which requires the WHOLE input string to match. So:
- `"user": "svc_"` only matches the literal username `svc_` (4 chars exactly). It will NOT match `svc_billing`.
- `"user": "svc_.*"` matches `svc_` followed by any suffix — `svc_billing`, `svc_etl`, etc. all match.

The correct diagnosis for the engineer's question:
> Your selector `"user": "svc_"` doesn't fire on `svc_billing` because Trino does FULL-STRING regex matching (Java's `Matcher.matches()`, not `Matcher.find()`). The regex `svc_` only matches the exact 4-character string `svc_`. To match anything STARTING with `svc_`, you need `"user": "svc_.*"` — the `.*` is required, not optional polish.

The responder's answer gives the right fix (`svc_.*`) but the wrong reason. An engineer reading this will conclude:
1. "Java regex always does substring matching" — wrong general lesson
2. "My problem was probably selector ordering" — wrong specific diagnosis
3. "Adding `.*` is one way to be more explicit" — wrong urgency level (it's the only way)

---

## What the teacher should investigate

The fact that the responder produced this answer when resources/05 and resources/22 BOTH now correctly explain matches() / full-string suggests one of:

1. **Resource retrieval gap**: The responder isn't pulling from the corrected sections. The answer cites `resources/05-multi-tenant-analytics.md` lines 2255–2314 — verify those lines actually contain the matches() / full-string explanation. The quoted snippet in the answer says "interpreted as a Java regex" but does NOT mention matches() or full-string — that section may need stronger inline anchoring of the matches() semantic right at the cite point.

2. **Conflicting signals in resources**: If ANY part of resources/ still says "substring" or "find()" or "Java regex matches anywhere in the string", the responder may be reading from that section. Re-scan all of resources/ for any phrasing like:
   - "substring"
   - "matches anywhere"
   - "matches the substring"
   - "doesn't need to match the entire"
   - "find()"
   - "looks for a substring"

3. **Buried correction**: The corrected explanation may be in resources/05 and resources/22 but not in the section the responder retrieves for "selector regex" / "user prefix" queries. The matches() / full-string explanation should be in a top-of-section CRITICAL CALLOUT or a dedicated "common mistake" callout immediately adjacent to ANY selector JSON example.

### Recommended teacher action for iter350

Add to `resources/05-multi-tenant-analytics.md` a **prominent CRITICAL section** at the very TOP of the resource-groups selector discussion, before any JSON example:

> ### CRITICAL: Trino uses FULL-STRING regex match (matches()), not substring (find())
>
> Most engineers expect `"user": "svc_"` to match `svc_billing` because in Java's `Pattern.matcher().find()`, `svc_` would match anywhere in the string. Trino does NOT use find(). Trino's StaticSelector calls `Matcher.matches()`, which requires the **entire** username to match the pattern.
>
> - `"user": "svc_"` matches ONLY the literal username `svc_`. It does NOT match `svc_billing`, `svc_etl`, etc.
> - `"user": "svc_.*"` matches `svc_billing`, `svc_etl`, `svc_reporting`, and also bare `svc_`.
> - `"user": "svc_.+"` matches `svc_billing` etc. but NOT bare `svc_` (requires at least one suffix char).
>
> The `.*` (or `.+`) at the end is **mandatory** for prefix matching — it is not optional polish.

Place this callout at the TOP of any subsection that includes a JSON selector example with a `"user"` field. The substring confusion is the single most common Trino selector mistake; responders need to encounter the matches() truth before they encounter any example.

---

## Sources used for verification

- [Trino Resource Groups docs (480)](https://trino.io/docs/current/admin/resource-groups.html) — confirms `"user"` is a Java regex.
- [PR #3023 — Adding regexp to match each user group](https://github.com/trinodb/trino/pull/3023) — references `userGroupRegexValue.matcher(userGroup).matches()`.
- [PR #27129 — queryText regex pattern](https://github.com/trinodb/trino/pull/27129) — confirms `matches()` is the match method used by selectors.
- WebSearch results explicitly stated: "the user field uses `userMatcher.matches()` which is the Java Matcher.matches() method for full-string matching."

---

# Judge Feedback — Iter 349 Q2

**Date**: 2026-05-28
**Phase**: extended
**Topic**: Postgres-to-Iceberg ingestion — Debezium handling of Postgres JSONB column, what type it lands as in Iceberg, and how to query it from Trino
**Result**: **PASS** (4.875 / 5.00)

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Every claim verifies. (1) Debezium emits Postgres JSONB as a JSON STRING via the `io.debezium.data.Json` semantic type — confirmed via Debezium docs + birdiecare/connect-smts deserialization docs (`"Debezium converts it in string"`, `"natively represented in the Kafka event structure as a string value"`). (2) Trino reads it as VARCHAR in Iceberg — confirmed; Parquet JSON logical type is UTF-8 byte_array per parquet.apache.org. (3) `settings->>'theme'` is Postgres-specific and not in Trino's grammar — Trino only has `json_extract`, `json_extract_scalar`, `JSON_VALUE`, `JSON_QUERY`. (4) `JSON_VALUE(... RETURNING varchar NULL ON EMPTY NULL ON ERROR)` is exact SQL/JSON standard syntax supported in Trino 467. (5) File-pruning limitation (no per-key Parquet stats on opaque JSON) is accurate — Trino's planner cannot see inside the string. (6) Spark `get_json_object` is the canonical PySpark API for the flatten pattern. No errors detected. |
| Beginner clarity | 4.5 | Structure is clean: sectioned by question part ("What Debezium sends" / "The Iceberg type" / "Querying syntax — NO" / "The real limitation" / "The production-grade fix"). Code blocks are annotated with intent comments. Explains "VARCHAR (a string)" inline. Loses 0.5 because the answer is long and an absolute beginner reading top-to-bottom hits the file-pruning analysis before the simple "use json_extract_scalar instead of `->>'`" takeaway is fully cemented. A 2-line TL;DR at top ("Lands as VARCHAR. `->>'` doesn't work — use `json_extract_scalar(settings, '$.theme')`") would have been ideal. |
| Practical applicability | 5.0 | Engineer knows exactly what to do: (a) the immediate Trino query syntax, (b) why their first instinct (`->>'`) will fail with a parse error, (c) when to upgrade from "store as VARCHAR" to "flatten hot keys", (d) a copy-pasteable PySpark recipe for the flatten pattern, (e) the dual-column model (`theme` + `settings_raw`) with both query paths shown. Mentions Iceberg 1.5.2 and Trino 467 explicitly — fits the production stack from prod_info.md. The 100x speedup figure is realistic for promoted low-cardinality fields. |
| Completeness | 5.0 | Three-part question fully answered: (1) what type it lands as — VARCHAR/JSON string, (2) Postgres operator support — explicit "NO" with the parse-error reason, (3) how to query it — `json_extract_scalar` + `JSON_VALUE`. Adds high-value bonus content the engineer will hit next: file-pruning limitation and the flatten + raw fallback pattern. No important nuance is missing for the question as asked. |
| **Average** | **4.875** | **PASS** (> 4.0) |

---

## What worked

- Direct answer to the operator syntax question — "NO, that won't work" with the actual workaround on the same line.
- The file-pruning callout is the key insight beyond the literal question and addresses the engineer's likely next problem.
- Production-grade fix is a runbook, not a sketch: typed promoted columns + raw VARCHAR fallback, with both query paths shown.
- Cite to `resources/13-postgres-to-iceberg-ingestion.md` ~line 3092 is accurate — the cited section actually contains the JSONB problem discussion plus the `io.debezium.data.Json` semantic-type callout.
- The answer correctly distinguishes `json_extract_scalar` (silent NULL on missing/malformed) from `JSON_VALUE` with `RETURNING ... ON EMPTY ... ON ERROR` (explicit handling) — this is the right nuance for a SaaS engineer who needs to decide between fast-and-forgiving vs. strict-with-error-control.

---

## Minor improvement suggestions (not blocking)

1. **Lead with a 2-line summary.** Even for an answer this strong, an absolute-beginner reader benefits from "Lands as VARCHAR. Use `json_extract_scalar(settings, '$.theme')` instead of `settings->>'theme'`. Read on for the file-pruning gotcha." at the very top. Then the structured sections.

2. **Could mention the `MAP<VARCHAR,VARCHAR>` alternative** for the specific "arbitrary key-value pairs that vary per customer" phrasing in the question — resources/13 line 3245–3257 has a decision table that explicitly covers "truly dynamic per-tenant settings" as a MAP candidate vs. flatten-hot-keys. The answer chose flatten + raw VARCHAR (which is the right default), but the question's framing ("vary per customer") hints at the MAP scenario. Not a deduction since the chosen recommendation is correct; just a completeness note.

3. **No mention of the new-key-arrival behavior** (i.e., what happens when a new `settings` key appears post-ingest). Resources/13 line 3234–3243 covers this thoroughly — engineer might ask this next.

---

## Sources used for verification

- [Debezium Event Deserialization docs](https://debezium.io/documentation/reference/stable/integrations/serdes.html) — confirms `io.debezium.data.Json` semantic type
- [birdiecare/connect-smts Debezium JSON deserialization](https://github.com/birdiecare/connect-smts/blob/master/doc/debezium-json-deserialization.md) — explicit "Debezium converts it in string"
- [Trino JSON functions (official docs)](https://trino.io/docs/current/functions/json.html) — confirms `json_extract_scalar`, `JSON_VALUE` syntax; no `->>'` operator
- [Parquet logical types](https://parquet.apache.org/docs/file-format/types/logicaltypes/) — JSON annotation is UTF-8 BYTE_ARRAY (opaque string)
- [Iceberg spec](https://iceberg.apache.org/spec/) — VARIANT type only in v3, not 1.5; JSON stored as string in 1.5.2

---

## Iter 349 End-of-Iteration Summary

**Iteration result**: **4.0625 / 5.00 — marginal PASS** (barely above the 4.0 floor; Q1 FAIL dragged what would have been a strong iteration down to the threshold)

### Iteration scores

| Question | Topic | Score | Result |
|---|---|---|---|
| Q1 | Multi-tenant analytics — Trino selector regex (svc_ prefix re-probe of iter348) | 3.25 | **FAIL** |
| Q2 | Postgres-to-Iceberg ingestion — Debezium JSONB → Iceberg VARCHAR, Trino querying | 4.875 | **PASS** |
| **Iteration avg** | | **4.0625** | **PASS** |

### Root cause analysis — Q1 failure (the bug persists across iter348 + iter349 fixes)

**The bug**: Responder again claimed Trino selectors do substring matching ("`svc_` does technically match `svc_billing` as a substring"). Trino actually uses `Matcher.matches()` (full-string), so `"user": "svc_"` matches ONLY the literal username `svc_` and nothing else.

**Why teacher's iter348 + iter349 fixes did not penetrate**:

1. **Resource fixes exist but are not at retrieval anchor points.** Teacher fixed resources/05 (iter348) and resources/22 (iter349 — line 5567 "anchored loosely (substring match)" → corrected to matches()/full-string). Both fixes are correct in isolation. But the responder still produced the substring claim, which means the retrieval path for "selector regex" / "user prefix" / "why doesn't my selector fire" pulled context that does NOT contain the matches() correction, OR pulled it alongside another section that still suggests substring semantics.

2. **The corrected text is descriptive, not prescriptive.** The responder cited resources/05 lines 2255-2314 — the quoted snippet says "interpreted as a Java regex" but does NOT explicitly contrast matches() vs find(). The corrected matches() callout is elsewhere in resources/05 (lines 2346, 2397, 2402 per state.json notes), not at the section the responder retrieved. The fix is in the file but not on the retrieval path.

3. **Default Java regex mental model leaks through.** When the responder's own internal model says "Java regex usually means substring (find())", and the resource section retrieved doesn't actively contradict that at the cite point, the responder fills in the gap from its prior. The fix needs to be at EVERY cite anchor where a `"user"` selector example appears — not just in dedicated callout sections.

4. **The wrong-answer template is more readable than the right-answer template.** The responder's wrong answer is well-structured: problem → "actual issue" theory A → theory B → fix → ordering. That structure is appealing precisely because it gives the engineer multiple paths to investigate. The corrected resource needs to make the matches() truth equally structured and equally near the top of the retrieval target — otherwise the responder will keep generating the readable-but-wrong template.

**Pattern**: This is the 2nd consecutive FAIL on the same selector regex semantics question across iter348 → iter349. Topic average held at 4.440 only because of the 141-question denominator; the recent-windows score on this sub-topic is markedly worse.

### What Q2 did well

- **Three-part question fully answered in order**: (a) what type JSONB lands as (VARCHAR), (b) Postgres operator support (explicit "NO" with parse-error reason), (c) Trino querying syntax (`json_extract_scalar` + `JSON_VALUE` with `RETURNING ... ON EMPTY NULL ON ERROR`).
- **Chain-of-custody accuracy**: every link verified (Debezium `io.debezium.data.Json` → Kafka string → Iceberg VARCHAR → Parquet JSON logical type = UTF-8 byte_array → Trino reads as VARCHAR). No factual errors.
- **Beyond-the-question value-add**: file-pruning limitation explained (no per-key Parquet stats inside opaque JSON string) — this is exactly the next problem the engineer will hit.
- **Production-grade runbook, not a sketch**: typed promoted columns via Spark `get_json_object` + `settings_raw VARCHAR` fallback, both query paths shown, realistic 100x speedup figure for low-cardinality promoted fields.
- **Stack-specific**: explicit Iceberg 1.5.2 + Trino 467 versions, matching prod_info.md.
- **Correct nuance choice**: distinguishes silent-NULL `json_extract_scalar` from strict `JSON_VALUE ... RETURNING ... ON EMPTY ... ON ERROR` — right tradeoff framing for a SaaS engineer.
- **Accurate cite**: resources/13 line 3092 actually contains the JSONB / Debezium serialization material referenced.

### Suggested focus for iter 350 — teacher needs a different strategy

The current strategy (fix the section, add callouts) has NOT penetrated to the responder. Two consecutive FAILs on the same sub-topic mean a structural change is needed:

1. **Inline the matches() correction at EVERY `"user"` selector JSON example in resources/05 + resources/22.** Not in a dedicated callout 50 lines away — directly above or below every JSON snippet that contains a `"user": "..."` field. The responder retrieves the JSON example; the matches() truth must travel with it.

2. **Add an anti-pattern section that explicitly enumerates the wrong claims.** Format like:
   > **WRONG** (do NOT write this): "`svc_` matches `svc_billing` as a substring because Java regex does substring matching."
   > **RIGHT**: Trino uses `Matcher.matches()` which requires the WHOLE username to match. `svc_` (no metachars) matches ONLY the literal 4-char string `svc_`. Use `svc_.*` to match any string starting with `svc_`.

   Naming the wrong template explicitly may keep the responder from generating it.

3. **Audit ALL resources/ files for any phrasing the responder could draw on for substring intuition**: "matches anywhere", "looks for", "contains", "substring", "find()", "partial match", "starts with" (without `.*`). Even in unrelated contexts (e.g., grep examples, Postgres LIKE, JavaScript `.match()`), nearby language about regex matching could leak the wrong mental model.

4. **Consider a re-probe-and-pin test on iter 350 Q1**: directly ask the selector regex question again. If the responder STILL produces substring, the issue is not solvable by resource edits alone and we need to escalate to a different mitigation (e.g., a top-of-resources/05 "READ FIRST" header that the responder cannot avoid).

5. **Q2 (JSONB) is stable — no action needed.** Resources/13 lines 3092-3275 are holding up across 6 consecutive strong PASSes. Continue probing other ingestion sub-topics (CDC schema evolution, type widening through CDC, Debezium connector failures, snapshot vs incremental tradeoffs) rather than re-probing JSONB.

### Topic running averages after iter 349

- Multi-tenant analytics: 4.440 / 141 questions (PASSED, but recent windows softening on selector regex)
- Postgres-to-Iceberg ingestion: 4.520 / 130 questions (PASSED, JSONB sub-topic strong)
- Iceberg maintenance: 4.603 / 36 questions (PASSED, no iter349 probe)
- Trino federation: 4.513 / 252 questions (PASSED, no iter349 probe)

All required topics remain above pass threshold. Continue extended phase per training deadline (2026-05-30 12:00 CST).

