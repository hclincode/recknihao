# Iter559 Judge Feedback — STRONG PASS 5.00 — 2026-06-07

## Headline
**ORDER-BY OVERSTATEMENT FIXED.** Iter558 Q3 hard-failed at 1.875 because the responder claimed "Trino strips top-level ORDER BY without LIMIT, returns random order." Iter559 teacher added r23 §3.1H canonical with the verbatim Trino 467 docs quote. **Iter559 Q1 result: responder now correctly says "A top-level ORDER BY without LIMIT IS honored in Trino" and routes the variance to ties + nested-redundant-drop.** Win confirmed. All 4 answers scored a perfect 5.00 on every dimension; overall average **5.00 / 5**.

## Per-question scores

### Q1 — ORDER BY honored or stripped? Why varies? (PRIMARY WIN CHECK)
**Scores: Accuracy 5, Completeness 5, Clarity 5, Actionability 5 = 5.00**

Responder said:
- "A top-level ORDER BY without LIMIT IS honored in Trino."
- Run-to-run variance comes from TIED `created_at` values → add unique tiebreaker `ORDER BY created_at DESC, event_id`.
- A NESTED ORDER BY (in CTE/view/subquery) MAY be dropped as redundant — put the final ORDER BY in the topmost SELECT.
- Cited r23 §3.1H.

Verified against trino.io/docs/467/sql/select.html (verbatim): *"an ORDER BY clause only affects the order of rows for queries that immediately contain the clause... Trino follows that specification, and drops redundant usage of the clause to avoid negative performance impacts."* Also corroborated by trino.io/blog/2019/06/03/redundant-order-by.html. Responder's answer maps 1:1 to spec. The iter558 overstatement ("stripped/random") is fully corrected — top-level honored, only nested-redundant is dropped, and the real variance causes (ties + nested-drop) are correctly named. THE r23 §3.1H CANONICAL ADDED THIS ITERATION ROUTED ON FIRST RE-PROBE.

### Q2 — Extract `event_meta.source` from ROW: bracket or dot?
**Scores: Accuracy 5, Completeness 5, Clarity 5, Actionability 5 = 5.00**

Responder said:
- Dot notation `event_meta.source` for named ROW fields.
- NOT bracket `event_meta['source']` (bracket is for MAP/ARRAY).
- For VARCHAR-JSON: `CAST(json_parse(event_meta) AS ROW(source VARCHAR, ...)).source`.
- Cited r09.

Verified against trino.io/docs/current/language/types.html (ROW): *"Named row fields are accessed with the field reference operator (.) using dot notation, while named or unnamed row fields are accessed by position with the subscript operator ([]), where the position starts at 1 and must be a constant."* Responder correctly distinguishes named-by-dot vs positional-by-bracket, and the CAST(json_parse(...) AS ROW(...)).field form is the canonical JSON-string → typed-ROW path. The iter558 r09 inverse-direction CAST-JSON-to-typed canonical is paying continued dividends.

### Q3 — Find ALL regex matches as a list
**Scores: Accuracy 5, Completeness 5, Clarity 5, Actionability 5 = 5.00**

Responder said:
- `regexp_extract_all(log_line, 'ERR_[0-9]{3}')` → ARRAY of all matches.
- UNNEST for one row per match.
- First-match-only = `regexp_extract` (single, not array).
- `$g` (not `\g`) for replacement back-references in `regexp_replace`.
- Cited r27.

Verified against trino.io/docs/current/functions/regexp.html. `regexp_extract_all(string, pattern) → array(varchar)` finds ALL occurrences; `regexp_extract(string, pattern) → varchar` returns first match. The `$g` back-reference rule for `regexp_replace` is also documented there. UNNEST guidance is right. r27's contextual coverage of regex (Oracle migration zone) routed cleanly without needing a standalone canonical — confirming the iter559 FIX B NO-OP audit was correct judgment.

### Q4 — Where do dbt model/column docs go?
**Scores: Accuracy 5, Completeness 5, Clarity 5, Actionability 5 = 5.00**

Responder said:
- Schema YAML `description:` is the primary place (NOT SQL comments — dbt ignores them).
- `{% docs name %}...{% enddocs %}` blocks in `.md` files + `{{ doc('name') }}` reference for reuse.
- `persist_docs: {relation: true, columns: true}` config emits `COMMENT ON TABLE/COLUMN` so docs land in engine metadata (visible via Trino `SHOW COLUMNS` / `DESCRIBE`).
- Clarifies `dbt docs generate` = HTML site vs `persist_docs` = engine metadata (orthogonal concerns).
- Cited r27.

Verified against docs.getdbt.com/docs/build/documentation, /reference/resource-properties/description, /reference/dbt-jinja-functions/doc, /reference/resource-configs/persist_docs. Every claim maps to official dbt docs verbatim. The two-channel split (HTML catalog vs engine COMMENT) is exactly right.

## Overall

| Q | Acc | Comp | Clarity | Action | Avg |
|---|---|---|---|---|---|
| Q1 ORDER BY (PRIMARY WIN CHECK) | 5 | 5 | 5 | 5 | 5.00 |
| Q2 ROW field access | 5 | 5 | 5 | 5 | 5.00 |
| Q3 regexp_extract_all | 5 | 5 | 5 | 5 | 5.00 |
| Q4 dbt docs placement | 5 | 5 | 5 | 5 | 5.00 |

**Iter559 average: 5.00 / 5 → STRONG PASS.** No fabricated absences, no overstatements, no identifier slips, no header-routing misses detected. Responder correctly cited r23 §3.1H (the new canonical), r09 (ROW), r27 (regex + dbt docs).

## What worked

1. **r23 §3.1H targeted canonical landed cleanly on FIRST re-probe.** The keyword anchors ("Trino ORDER BY without LIMIT", "ORDER BY ignored Trino", "why does my row order vary between runs", "ORDER BY tiebreaker") routed Haiku straight to the canonical. Responder picked up the verbatim-quote-anchored fact ("top-level honored, nested-redundant dropped"), the three-shape worked contrast (top-level / nested / tied), and the tiebreaker fix. The 4-row DO-NOT-WRITE prevented the iter558 overstatement from re-emerging.
2. **FIX B NO-OP audit proved correct.** The 3 skipped candidates (COALESCE family, ROW dot-access standalone, regexp_extract_all distinction) all proved to have sufficient contextual coverage — confirmed by Q2 (dot notation answered cleanly) and Q3 (regexp_extract_all answered cleanly). Skipping was the right call; manufacturing canonicals would have churned without lift.
3. **Citations were specific.** Responder named r23 §3.1H, r09, r27 — not vague hand-waves. This is the find-by-keyword pattern working as designed.

## What to do next (iter560)

All 4 strong → polish-mode. Continue proactive audits, not new canonicals.

**Recommended iter560 priorities (in order):**
1. **Re-probe ORDER-BY-determinism from a 3rd angle** to confirm the fix is durable (not single-question luck). Suggested phrasings:
   - "I put ORDER BY in a CTE and the outer query came back unordered — bug?"
   - "Does adding LIMIT change whether ORDER BY runs?"
   - "My nightly job sorts events by ts but the export file order changes — why?"
   These hit the nested-dropped and LIMIT-doesn't-make-it-run angles specifically.
2. **Proactive audit pass on r23 §3.1A–§3.1H cluster.** With §3.1H newly slotted, walk the whole 3.1x cluster to confirm no contradictions, no stale "ORDER BY needs LIMIT to execute" myths left in adjacent sections, no broken cross-refs from the new §3.1H back-link targets (r07 §5, r22 §3.3A/§13.5, r27 NULLS-default).
3. **Federation row stays at 4.49944/310 (locked).** Do not probe federation in iter560 unless the lock is explicitly released. The currently strong-passing topics (CBO, partition-design, dbt-snapshots, model-contracts, source-freshness) are all candidates for low-touch re-probes to confirm stability under continued questioning.
4. **DO NOT churn for the sake of churn.** This iteration's NO-OP FIX B was correct judgment. Continue the discipline of "only add a canonical when there's a verified routing-clean gap, not when the topic feels under-papered."

No new gaps identified. No slips to fix. Iter559 is a clean strong-pass win on the iter558 hard-fail re-probe.
