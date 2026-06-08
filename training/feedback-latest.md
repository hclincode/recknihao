# Iter 716 — Judge Feedback

## Per-question scores (Accuracy / Completeness / Clarity / Actionability, each 1–5)

### Q1 — Iceberg snapshot expiry + remove_orphan_files (+ "keep last 10" probe)

**Sub-scores: Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00**

- `ALTER TABLE iceberg.schema.table EXECUTE expire_snapshots(retention_threshold => '7d')` — VERIFIED correct per trino.io/docs/467/connector/iceberg.html (Iceberg connector → procedure `expire_snapshots`: `ALTER TABLE test_table EXECUTE expire_snapshots(retention_threshold => '7d')`).
- `ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d')` — VERIFIED correct per same source.
- Responder EXPLICITLY stated "Trino 467 doesn't have a direct 'keep N snapshots' option. It works with time thresholds ('7d','3d')—not snapshot counts." — VERIFIED correct: Trino 467's `expire_snapshots` is duration-driven via `retention_threshold` only; `retain_last` was added in Trino 479 and is a Spark-Iceberg-Java-API concept on the production stack. r17 + r11:520 both already pin this correctly.
- **The iter715 Q3 "(keep last 10)" inline-comment slip DID NOT RECUR.** This was a one-off responder-comment leak in iter715; r17 + r11 content was sufficient and the responder this iteration handled the explicit count-based phrasing cleanly with the correct duration-only framing. **No iter717 FIX-A needed on this front.**

### Q2 — Normalize dirty emails (LOWER + TRIM)

**Sub-scores: Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00**

- `LOWER(TRIM(email))` — VERIFIED correct per trino.io/docs/467/functions/string.html (`trim(string) → varchar`: "Removes leading and trailing whitespace from string." `lower(string) → varchar`: "Converts string to lowercase.").
- "WHERE LOWER(email)='me@x.com' skips partition pushdown" — CORRECT: function-wrapped predicates defeat Iceberg partition/file-level pruning; storing the pre-normalized value at ingest is the standard fix (and matches the iter679/iter687 "function on the column kills pushdown" lock).
- Bulletproof reference answer; appropriate trade-off framing (SQL vs dbt vs upstream).

### Q3 — find account_id NOT in expected 8-digit format (TWO INVALID Trino 467 forms)

**Sub-scores: Acc 1 / Comp 3 / Clar 3 / Act 2 = 2.25**

**CRITICAL — both pattern-match forms offered are INVALID Trino 467:**

1. **`account_id NOT LIKE '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'` — WRONG.** VERIFIED per trino.io/docs/467/functions/comparison.html (LIKE): Trino's LIKE supports ONLY `_` (single char) and `%` (zero or more chars) wildcards (plus `ESCAPE`). It does **NOT** support `[...]` bracket character classes — that is a **SQL Server LIKE extension**. In Trino 467, `LIKE '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'` treats `[`, `0`, `-`, `9`, `]` as **literal characters** and matches the literal string `"[0-9][0-9]..."`, NOT 8 digits. Net effect: the predicate matches essentially nothing, and `NOT LIKE '[0-9]...'` returns essentially every row — the diagnostic is meaningless. Silent-wrong, no parse error.

2. **`account_id ~ '^\d{8}$'` / `NOT (account_id ~ '^\d{8}$')` — WRONG.** VERIFIED per trino.io/docs/467/functions/regexp.html: Trino 467 has NO `~`, `~*`, `!~`, or `!~*` regex-match operators. Those are **PostgreSQL POSIX-regex operators**. Trino exposes regex only via FUNCTIONS: `regexp_count`, `regexp_extract`, `regexp_extract_all`, `regexp_like`, `regexp_position`, `regexp_replace`, `regexp_split`. Writing `col ~ 'pattern'` raises `mismatched input '~'` at parse time. Hard parse-time failure.

**Correct Trino 467 forms** (which the responder did NOT actually write, though it cross-referenced regexp_like as "an alternative"):
```sql
WHERE NOT regexp_like(account_id, '^[0-9]{8}$')
-- or
WHERE NOT regexp_like(account_id, '^\d{8}$')   -- \d works in Java/JONI regex
```

This is the same Postgres-ism leak family as the iter714 Q4 `::integer` cast leak — except this iteration emits TWO simultaneous Postgres/SQL-Server dialect leaks in a single answer. Q3 must be heavily penalized on Accuracy.

**Resource-gap audit (findability check):**
- Grep `LIKE` bracket-class inoculation: **NONE** found. No "Trino LIKE supports only `%` and `_`, not `[0-9]` bracket character classes" defang exists anywhere in resources/.
- Grep `~` / `~*` / Postgres regex-operator inoculation: **NONE** found. r23:2494 (ILIKE) is the closest neighbor, and r27:1057 has an `RLIKE`-NOT-IN-Trino defang — but neither covers the `~` infix operator that the responder reached for.
- r23:464 mentions `regexp_like(filename, '(?i)\.csv$')` in passing; r27:1032-1057 has the only LEADING CANONICAL for `regexp_like(...)` multi-keyword search. Neither is keyword-anchored on "8 digits", "exactly N digits format", "account_id format", "account number format", "validate digit format", "non-numeric account", "regex character class Trino", or "POSIX regex Trino".
- The cross-ref in the answer mentioned `regexp_like` exists, but the SQL the responder actually WROTE used the two invalid forms. This is exactly the keyword-router-pulls-wrong-content pattern.

**Both gaps are genuine findable-but-missing dialect inoculations.** **→ iter717 FIX-A candidate (priority 1, two-defects-in-one-answer).**

### Q4 — GROUP BY ... HAVING SUM() > threshold

**Sub-scores: Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00**

- `GROUP BY subscription_plan HAVING SUM(lifetime_spend) > 10000` — VERIFIED correct per trino.io/docs/467/sql/select.html.
- `WHERE SUM(...) > 10000` → parse error defang — CORRECT (aggregates are illegal in `WHERE`).
- Clause-order recap `FROM → WHERE → GROUP BY → HAVING → SELECT → ORDER BY` — CORRECT standard SQL semantic evaluation order.
- `COUNT(DISTINCT account_id)` for plan-size context is a nice bonus.
- Bulletproof reference answer.

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|----:|----:|----:|----:|----:|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 1 | 3 | 3 | 2 | 2.25 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |
| **Sum** | 16 | 18 | 18 | 17 | — |
| **Dim avg** | 4.00 | 4.50 | 4.50 | 4.25 | — |

**Overall = (5.00 + 5.00 + 2.25 + 5.00) / 4 = 17.25 / 4 = 4.3125**
Cross-check via 16-subscore sum: (20 + 20 + 9 + 20) / 16 = 69 / 16 = **4.3125** ✓
Cross-check via dim-avg: (4.00 + 4.50 + 4.50 + 4.25) / 4 = 17.25 / 4 = **4.3125** ✓

**Verdict: PASS** (4.3125 ≥ 3.5 floor; margin +0.8125). Per directive, **overall average governs, no per-Q veto** — Q3 2.25 is flagged in prose as the iter717 FIX-A driver but does not by itself fail the iteration.

## Explicit answers required by the directive

**(1) Q1 keep-last-N confusion recurrence?** **DID NOT RECUR.** The responder explicitly stated Trino 467's `expire_snapshots` is duration-driven via `retention_threshold` and that there is NO keep-N-snapshots count parameter, framing the count-based alternative as orchestration in dbt/Spark. This confirms the iter715 "(keep last 10)" was a **one-off responder narrative-comment slip**, and r17 + r11:520 in-resource content is sufficient. **No iter717 FIX-A needed on the expire_snapshots prose-defang front.**

**(2) Q3 LIKE-bracket-class + `~`-regex-operator forms — GENUINE NEW dialect defects?** **YES, BOTH.** Grep audit of resources/ confirms:
- No "Trino LIKE supports only `%` and `_`; `[0-9]` bracket character classes are SQL-Server-only" inoculation exists anywhere.
- No "Trino has no `~` / `~*` / `!~` regex operators (Postgres POSIX-regex); use `regexp_like(col, pattern)` function" inoculation exists anywhere (closest cousin is the r27:1057 `RLIKE`-not-in-Trino defang, which does not cover the `~` infix operator).
- This is the same dialect-leak family as iter714 Q4's `::integer` Postgres cast. **iter717 FIX-A priority 1.**

## Teacher actionable guidance — iter717 FIX-A

Add to **r23 (SQL best practices)** as a single co-located LEADING CANONICAL section, keyword-anchored on `regex Trino`, `validate format Trino`, `match exactly N digits Trino`, `account number format Trino`, `phone number format Trino`, `LIKE character class Trino`, `LIKE 0-9 Trino`, `Trino LIKE wildcards`, `Postgres ~ operator Trino`, `tilde regex Trino`, `POSIX regex Trino`:

```sql
-- LEADING CANONICAL — find rows whose <id> column does NOT match exactly N digits (or any format-validation diagnostic)
SELECT account_id, user_id
FROM iceberg.analytics.usage_table
WHERE NOT regexp_like(account_id, '^[0-9]{8}$')   -- or '^\d{8}$' (\d works in Java/JONI)
ORDER BY account_id;
```

Add a co-located DO-NOT-WRITE table with **inline-marked WRONG** rows (per the Defang DO-NOT-WRITE Snippets lesson — make wrong forms un-copyable, make canonical the copy-attractive block):

| Wrong form (inline-marked WRONG) | Why wrong | Correct Trino 467 form |
|---|---|---|
| `account_id NOT LIKE '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'` WRONG | Trino LIKE supports ONLY `%` (any sequence) and `_` (single char); `[0-9]` bracket char-classes are a **SQL Server LIKE extension**, not Trino. The brackets are treated as **literal characters** — predicate matches the literal string `"[0-9]..."`, so the diagnostic is silently broken (no parse error). | `NOT regexp_like(account_id, '^[0-9]{8}$')` |
| `account_id ~ '^\d{8}$'` WRONG | The `~` / `~*` / `!~` / `!~*` infix regex operators are **PostgreSQL POSIX-regex syntax**, NOT Trino. Trino 467 raises `mismatched input '~'` at parse time. | `regexp_like(account_id, '^\d{8}$')` |
| `account_id !~ '^\d{8}$'` WRONG | Same Postgres POSIX leak — parse error. | `NOT regexp_like(account_id, '^\d{8}$')` |
| `account_id RLIKE '^\d{8}$'` WRONG | `RLIKE` is Hive/Spark/MySQL, not Trino. `Function 'rlike' not registered`. | `regexp_like(account_id, '^\d{8}$')` |

Add a one-paragraph callout:

> **Trino regex is functions-only.** Trino 467's complete regex surface is the seven functions documented at trino.io/docs/467/functions/regexp.html: `regexp_count`, `regexp_extract`, `regexp_extract_all`, `regexp_like`, `regexp_position`, `regexp_replace`, `regexp_split`. There are NO infix regex operators (`~`, `~*`, `!~`, `!~*` are Postgres). There is NO `RLIKE` (that's Hive/Spark/MySQL). The pattern grammar is Java/JONI (so `\d`, `\w`, `\s` all work, plus POSIX classes like `[[:digit:]]`). `regexp_like` is CONTAINS-by-default — anchor with `^...$` for full-string match.

> **Trino LIKE wildcards are `_` and `%` ONLY.** Per trino.io/docs/467/functions/comparison.html, Trino's LIKE supports exactly two wildcards: `_` (single character) and `%` (any sequence). Bracket character classes like `[0-9]`, `[a-z]`, `[^abc]` are a **SQL Server LIKE extension** — Trino treats them as LITERAL characters. For character-class matching, switch to `regexp_like`.

Cross-ref from r07 (analytical query patterns, format-validation neighborhood) and from r23's existing dialect table (the existing ILIKE row at r23:2494 is the right neighbor — add the two new rows immediately adjacent).

## Holds

- HOLD all iter534–715 locks (~267+ entries across 17 resource files; iter716 was NO-OP per state.json).
- HOLD r22 federation guardrails (72-iter ZERO probe streak; 4.49944 vs 4.5 thin — do NOT touch).
- HOLD r17 expire_snapshots / remove_orphan_files content (confirmed bulletproof this iteration).
- Federation NOT probed this iter — row UNCHANGED.

## Do NOT bump state.json

Per directive, orchestrator handles state.json updates. Judge does not modify it.
