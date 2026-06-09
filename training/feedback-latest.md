# iter793 Judge Feedback — durability-breadth sweep (DEFAULT NO-OP probe, 4 fresh adjacent topics)

**Verdict: PASS — overall avg 4.31/5.** One genuine defect (Q3 regex `\|` escaping). Q1/Q2/Q4 clean.

All dialect claims verified against trino.io/docs/467 (regexp.html, types.html, comparison.html, aggregate.html, functions/string.html). resources/ NOT treated as ground truth.

---

## Per-question scores

### Q1 — FLOAT→DECIMAL money (`CAST(amount_dbl AS DECIMAL(18,2))`)
| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 4 |
| Clarity | 5 |
| Actionability | 5 |
| **Avg** | **4.75** |

VERIFIED: `CAST(double AS DECIMAL(18,2))` rounds **HALF_UP** (matches the standing CAST-rounds pin) → `19.999999998 → 20.00`. Correct, exact fixed-point fix for a double source. SUM-widening-to-`decimal(38,s)` claim: aggregate.html only shows `sum(x) → same as input` generically, but Trino's documented decimal arithmetic widens sum precision to 38 to prevent overflow — the responder's claim is correct in practice; minor (-1 completeness for not noting the agg page doesn't spell it out). Nuance, not a defect: for money, define the column as DECIMAL from the start rather than store double then cast — but given a double SOURCE, `CAST AS DECIMAL(18,2)` is the right move.

### Q2 — split "Jane Smith" (`split_part(full_name,' ',1/2)`)
| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
| **Avg** | **5.00** |

VERIFIED against functions/string.html: `split_part(string, delimiter, index) → varchar`, **1-indexed**, returns NULL if index > number of parts. `split_part(full_name,' ',1)` = first_name, `(...,2)` = last_name. Exactly right, including the out-of-range→NULL note. Clean.

### Q3 — match ANY keyword (`regexp_like(description, 'refund\|chargeback\|dispute')`)
| Axis | Score |
|---|---|
| Accuracy | 2 |
| Completeness | 4 |
| Clarity | 4 |
| Actionability | 2 |
| **Avg** | **3.00** |

**DEFECT — emitted-SQL escaping defeats the alternation.** The responder emitted the pattern string `'refund\|chargeback\|dispute'` with **BACKSLASH-PIPE `\|`**.

VERIFIED:
- trino.io/docs/467/functions/regexp.html: Trino regex uses **Java `java.util.regex` pattern syntax**. In Java regex the alternation metacharacter is a **PLAIN `|`**; a backslash-escaped `\|` is an **escaped LITERAL pipe** — it matches a literal `'|'` character, NOT alternation.
- trino.io/docs/467/language/types.html: Trino single-quoted string literals do **NOT** process backslash escapes (only `''` escapes a quote; backslash is a literal char). So the engine receives the literal bytes `refund\|chargeback\|dispute`, and Java regex reads each `\|` as a literal pipe.
- **RESULT:** `regexp_like(description, 'refund\|chargeback\|dispute')` matches the literal substring `refund|chargeback|dispute` (with literal pipe chars) — which essentially never appears in real text → the filter returns **(almost) NO rows**. Silent-wrong.
- **CORRECT Trino form:** `regexp_like(description, 'refund|chargeback|dispute')` with **PLAIN unescaped pipes** (alternation).

Mitigating: the responder's **PROSE is correct** — it says "the `|` (pipe) is regex alternation = any one of these", contains-check, no anchors. The intent and explanation are right; only the **emitted code-string** carries the wrong `\|`. Hence Accuracy/Actionability drop to 2 (the copy-paste SQL is broken) while Completeness/Clarity stay at 4 (the concept is taught correctly).

**RESPONDER SLIP vs RESOURCE DEFECT — investigated:**
- `resources/27-oracle-plsql-to-dbt-trino.md:1092` (fenced code block, LEADING CANONICAL): `WHERE regexp_like(body, 'refund|cancel|chargeback');` — **PLAIN pipe, CORRECT.**
- `resources/23-sql-best-practices-olap.md:2783` (markdown **table cell**): `` `regexp_like(col, 'a\|b\|c')` `` — shows `\|`.
- `resources/27-oracle-plsql-to-dbt-trino.md:1112-1113` (markdown **table cells**, RLIKE-inoculation "correct form" column): `regexp_like(body, 'refund\|cancel\|chargeback')` — shows `\|`.

**Root cause = markdown table-cell pipe escaping.** Inside a markdown `|`-delimited table a literal pipe MUST be written `\|` or it breaks the column layout; when rendered, `'a\|b\|c'` displays as `'a|b|c'`. So in those table rows the `\|` is a **rendering artifact**, not an authoring error — the *rendered* text is correct. BUT the Haiku responder reads **raw markdown source**, not rendered HTML, so when it pattern-matches to the r23:2783 table row (keywords "contains any of") and copies verbatim, it emits the raw `\|`. The correct canonical fenced block at r27:1092 sits in a different resource under different keyword anchors and was not the source the responder latched onto.

**Verdict: BORDERLINE responder-slip enabled by a raw-source-vs-rendered findability trap.** Not a pure responder hallucination (the `\|` literally exists in r23:2783 source the responder reads), and not a pure resource defect (the canonical r27:1092 is correct and the table `\|` renders correctly). The highest-findability hit for this exact question ("contains any of a, b, c") is the r23:2783 table row, whose raw form carries `\|`. → iter794 = **FIX-A** (see below).

### Q4 — NULL-safe NOT-equal (`WHERE status IS NULL OR status != 'archived'`)
| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 4 |
| Clarity | 5 |
| Actionability | 5 |
| **Avg** | **4.75** |

VERIFIED against comparison.html: correct three-valued-logic handling. `NULL != 'archived'` → UNKNOWN → row dropped, so `OR status IS NULL` is required to keep NULLs. The answer works and the 3VL explanation is accurate.

**Completeness note (not a defect):** the cleaner single-expression idiom is `WHERE status IS DISTINCT FROM 'archived'`. VERIFIED: `IS DISTINCT FROM` is null-safe — docs say it "treats NULL as a known value and guarantees a TRUE/FALSE outcome"; `NULL IS DISTINCT FROM 'archived'` → TRUE, so NULL rows are kept and 'archived' excluded — exactly the question's hint ("keep rows where status IS NULL"). The responder's `IS NULL OR !=` form is correct and equivalent; -1 completeness only for not surfacing `IS DISTINCT FROM` as the idiomatic one-liner (the standing IS-DISTINCT-FROM pin).

---

## Overall

| Q | Avg |
|---|---|
| Q1 | 4.75 |
| Q2 | 5.00 |
| Q3 | 3.00 |
| Q4 | 4.75 |
| **Overall** | **4.31** |

**PASS** (overall avg 4.31 ≥ 3.5; no single-Q veto). Q3 is the lone soft spot at 3.00 — works conceptually, broken as emitted SQL.

---

## iter794 designation: **FIX-A (targeted, low-risk)**

The `\|` in the r23:2783 table cell (and r27:1112-1113) is a markdown-rendering necessity but a raw-source trap for the Haiku responder. Fix the findability/source hygiene so the responder copies a plain `|`:

1. **r23:2783** — the highest-findability row for "contains any of". Move the canonical OUT of the table cell into an adjacent **fenced code block** (where pipes need no escaping), e.g. add right under the dialect table:
   ```
   -- Contains ANY of several terms (alternation; replaces chained OR LIKE):
   regexp_like(col, 'a|b|c')   -- PLAIN pipes = alternation
   ```
   Keep the table row but add an explicit inline caution: *"(in this markdown table the pipe renders as `\|` for layout; the actual SQL uses a PLAIN `|` — `regexp_like(col, 'a|b|c')` — NEVER write `\|`, which matches a literal pipe character)."*
2. **Add a defang** at the r27 multi-keyword canonical and/or the r23 regex card: a WRONG/DO-NOT-COPY row stating `regexp_like(col, 'a\|b\|c')` with `\|` is **silent-wrong** — `\|` is an escaped literal pipe in Java regex + Trino does not process backslash escapes in string literals, so it matches the literal substring `a|b|c` and returns ~no rows. Canonical = plain `|`.
3. **Cross-ref / keyword anchors**: ensure the r27:1083 LEADING CANONICAL (which already has correct plain-pipe code at r27:1092) carries the question keywords "refund/chargeback/dispute", "match any keyword", "any of these words" so the responder lands on the fenced-code canonical, not the table cell.

This is FIX-A (surface the plain-pipe canonical in a fenced block + defang the `\|` form + keyword anchors), NOT a broad rewrite. r27:1092 is already correct; the job is to make the plain-pipe form the copy-attractive hit and inoculate the `\|` raw-source trap. Per the "Defang DO-NOT-WRITE Snippets" pin, make the canonical plain-`|` fenced block the copy-attractive target and mark `\|` un-copyable/WRONG inline.

**Secondary (optional, low priority):** add `IS DISTINCT FROM 'archived'` as the idiomatic NULL-safe single-expression alternative alongside the `IS NULL OR !=` form, so Q4-style questions can surface the cleaner one-liner.
