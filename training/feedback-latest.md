# Judge Feedback — Iter 614 (EXTENDED PHASE)

**Overall: 4.6875 — PASS** (margin +1.1875 above the 3.5 floor). Federation NOT probed — the 4.49944/310 row is unchanged.

Trino pinned to **467**. All four answers verified against trino.io/docs/467 + Trino issue tracker; corrections verified before asserting.

---

## Headline

Breadth probe across four string/parse/aggregate canonicals: Q1 strip-non-digits (regexp_replace 2-arg remove), Q2 VARCHAR→timestamp parse (date_parse/parse_datetime), Q3 collapse-rows-to-map (map_agg), Q4 collect-names-to-array (array_agg). **Three of four are clean and docs-verbatim correct.** The lone real defect is **Q2 form 1**: it references the SELECT output alias `occurred_at` in the WHERE clause — **INVALID in Trino 467** (WHERE is evaluated before the SELECT list, so output aliases are not resolvable there). The parse functions and format strings are all correct; the slip is purely the alias-in-WHERE placement on the *first-shown* form. An engineer who pastes form 1 hits `Column 'occurred_at' cannot be resolved`. Form 2 (no WHERE) is clean.

---

## Per-question scores

### Q1 — strip non-digits from a phone string → '5551234567'  →  Acc 5 / Comp 5 / Clar 5 / Act 5 = **5.00 STRONG PASS**
`regexp_replace(phone_number, '[^0-9]') AS digits_only` — the **2-arg remove form**.
- **VERIFIED** trino.io/docs/467/functions/regexp.html verbatim: `regexp_replace(string, pattern) → varchar` — *"Removes every instance of the substring matched by the regular expression pattern from string."* So the 2-arg form removes EVERY match (global), exactly what's wanted. **This is the new-canonical route the iter614 teacher added, and it LANDED correctly.**
- `[^0-9]` is a correct negated character class for "any non-digit." Stripping every non-digit from a formatted phone string yields the bare digit run. Correct.
- **`\D` claim VERIFIED TRUE**: Trino regex functions use Java pattern syntax (default JONI engine; re2j selectable via the regexp library property). `\D` (= `[^\d]`, non-digit) is a standard Java/re2j shorthand and is supported. So `regexp_replace(phone_number, '\D')` is an equivalent valid alternative — the responder's "both work in Trino" is accurate. (Trino does not interpret backslash escapes in standard string literals, so `'\D'` passes the literal `\D` to the regex engine intact. Fine as written.)
- "Exactly how Postgres does it" — loosely acceptable framing (Postgres `regexp_replace` needs the `'g'` flag for global; Trino's 2-arg form is implicitly global). Minor imprecision, not docked.
- Zero defects.

### Q2 — parse VARCHAR '2026-06-07 14:30:00' → real timestamp for date math  →  Acc 3.5 / Comp 4 / Clar 4.5 / Act 3.5 = **3.875 PASS (with a real slip on form 1)**

Two forms offered:
- **Form 1**: `SELECT event_id, parse_datetime(timestamp_text, 'yyyy-MM-dd HH:mm:ss') AS occurred_at FROM events WHERE occurred_at > current_timestamp - INTERVAL '7' DAY;`
- **Form 2**: `SELECT event_id, CAST(date_parse(timestamp_text, '%Y-%m-%d %H:%i:%S') AS TIMESTAMP(6)) AS occurred_at FROM events;`

**Format strings — ALL CORRECT (verified):**
- parse_datetime uses **Joda** `'yyyy-MM-dd HH:mm:ss'` — docs: `parse_datetime(string, format) → timestamp with time zone`, JodaTime DateTimeFormat. Correct pattern.
- date_parse uses **MySQL** `'%Y-%m-%d %H:%i:%S'` — docs verbatim: `%i` = *"Minutes, numeric (00 .. 59)"*, `%S` = *"Seconds (00 .. 59)"*, `%Y` four-digit year, `%H` hour 00–23. Returns `timestamp(3)`. Correct — and critically the responder did **not** confuse the two dialects (no `%Y` fed to parse_datetime, no `yyyy` fed to date_parse). Good — no FORMAT-STRING-MISMATCH.
- The two functions are correctly matched to their respective dialects.

**CRITICAL DEFECT — form 1 alias-in-WHERE is INVALID Trino 467:**
The WHERE clause references `occurred_at`, which is the **SELECT-list output alias** of the `parse_datetime(...)` expression. In Trino, **WHERE is evaluated before the SELECT list is projected**, so output aliases are not in scope in WHERE. This is the same scoping rule that blocks aliases in GROUP BY (trinodb/trino #16533, "Using alias in group by is not supported by Trino"). Form 1 fails with **`Column 'occurred_at' cannot be resolved`**. (ORDER BY *can* see output aliases — docs place ORDER BY after GROUP BY/HAVING — but WHERE cannot.) An engineer pasting form 1 (the first-shown form) hits an immediate analyzer error.

**Correct fixes** (any of):
- Repeat the expression in WHERE: `WHERE parse_datetime(timestamp_text, 'yyyy-MM-dd HH:mm:ss') > current_timestamp - INTERVAL '7' DAY`
- Wrap in a subquery/CTE: `WITH parsed AS (SELECT event_id, parse_datetime(...) AS occurred_at FROM events) SELECT * FROM parsed WHERE occurred_at > current_timestamp - INTERVAL '7' DAY`

**Secondary note (completeness):** `parse_datetime` returns `timestamp(3) **with time zone**`, whereas form 2's `date_parse` returns a plain `timestamp(3)` (cast to `timestamp(6)`). The two forms produce **different types** for the same `occurred_at` column. parse_datetime's tz-aware result compared against `current_timestamp` (also tz-aware) is fine; date_parse's plain timestamp would need a tz-aware partner for the same comparison. The responder did not flag that the two forms differ in return type — a real (minor) completeness gap.

**Why 3.875 and not higher:** form-2 is fully correct (parse + cast + no WHERE-alias) and the format-string scholarship is exactly right, so accuracy is mostly intact; but the FIRST form errors on paste (Acc/Act docked to 3.5) and the tz-type difference is unmentioned (Comp 4). Routed-but-mis-applied slip, not a knowledge gap.

### Q3 — collapse feature-toggle rows into one `{feature_name: enabled_flag}` map per user  →  Acc 5 / Comp 4.5 / Clar 5 / Act 5 = **4.875 STRONG PASS**
`map_agg(feature_name, enabled_flag) AS feature_flags ... GROUP BY user_id`.
- **VERIFIED** aggregate.html: `map_agg(key, value) → map<K,V>` — *"Returns a map created from the input key/value pairs."* Builds one map per group; with `GROUP BY user_id` that's one map row per user. Correct.
- element_at + map_filter mentions are correct downstream-access helpers (`element_at(feature_flags, 'dark_mode')`, `map_filter` to keep only enabled). Useful value-add.
- **Minor completeness ding (−0.5)**: `map_agg` **errors on duplicate keys within a group** (`Duplicate map key ... was found`). The question premise ("a user's many feature-toggle rows," one row per feature per user) means no duplicate `feature_name` per `user_id`, so it's safe here — but a one-line caveat ("if a feature can repeat per user, dedup first or use `multimap_agg`") would have been the fully-complete answer. Acceptable omission given the premise; not an accuracy error.
- No `::`-cast, no invalid placement. Correct.

### Q4 — collect all line-item product names per order into one array  →  Acc 5 / Comp 5 / Clar 5 / Act 5 = **5.00 STRONG PASS**
`array_agg(product_name) AS product_list ... GROUP BY order_id`.
- **VERIFIED** aggregate.html: `array_agg(x) → array<[same as input]>` — *"Returns an array created from the input x elements."* One array per group; `GROUP BY order_id` → one row per order. Correct.
- **ORDER-BY-inside-array_agg mention VERIFIED**: docs show `array_agg(x ORDER BY y DESC)` and note array_agg *"produce[s] different results depending on the order of input values"* — so `array_agg(product_name ORDER BY line_number)` for deterministic ordering is a correct and useful tip (array ordering is otherwise nondeterministic). Right call to mention it.
- Zero defects.

---

## Dimension averages → overall

| Dim | Q1 | Q2 | Q3 | Q4 | Avg |
|---|---|---|---|---|---|
| Accuracy | 5 | 3.5 | 5 | 5 | 4.625 |
| Completeness | 5 | 4 | 4.5 | 5 | 4.625 |
| Clarity | 5 | 4.5 | 5 | 5 | 4.875 |
| Actionability | 5 | 3.5 | 5 | 5 | 4.625 |

Overall = (4.625 + 4.625 + 4.875 + 4.625) / 4 = **4.6875**.
Per-question cross-check: (5.00 + 3.875 + 4.875 + 5.00) / 4 = **4.6875** — agree.
**Overall average governs the label — PASS (≥ 3.5).** No per-question quality gate applied; Q2 form-1 flagged separately as a quality concern below.

---

## Q1 verdict (new regexp_replace canonical)
**LANDED — confirmed correct.** The 2-arg remove form `regexp_replace(string, pattern)` is valid Trino 467 and *"Removes every instance of the substring matched by the regular expression pattern"* (docs verbatim). `[^0-9]` strips non-digits; the `\D` alternative is genuinely supported (Java pattern syntax). The iter614 teacher's strip-non-digits content routed cleanly on the first probe. No `::`-cast, no fabrication.

## Q2 verdict (CRITICAL)
**Form 1's `WHERE occurred_at > ...` is INVALID Trino 467.** A WHERE clause cannot reference a SELECT output alias because WHERE is evaluated before the SELECT projection (same scoping basis as alias-in-GROUP-BY, trinodb/trino #16533). Form 1 errors with `Column 'occurred_at' cannot be resolved`. **Diagnosis: routed-but-mis-applied / copy-paste-incompleteness** — the parse-function knowledge is correct (right dialects, right specifiers), but the worked example pasted a non-runnable WHERE-on-alias pattern onto the first form. Not a missing-resource problem; the resource needs an explicit guardrail at the parse-timestamp landing point.

## Iter615 directives

**1. (PRIMARY, targeted) Add an alias-in-WHERE guardrail at the date_parse/parse_datetime canonical (r27, and r07/r09 wherever the string→timestamp parse worked-example lives).** Insert a one-line note + corrected example so the responder stops pasting the alias into WHERE:
> "Do NOT reference the parsed-timestamp output alias in WHERE — in Trino, WHERE is evaluated before the SELECT list, so the alias is not yet in scope (`Column '<alias>' cannot be resolved`). Repeat the expression in WHERE, or filter in an outer query / CTE."
>
> Correct: `WHERE parse_datetime(timestamp_text, 'yyyy-MM-dd HH:mm:ss') > current_timestamp - INTERVAL '7' DAY`
> Or: `WITH parsed AS (SELECT event_id, parse_datetime(timestamp_text, 'yyyy-MM-dd HH:mm:ss') AS occurred_at FROM events) SELECT * FROM parsed WHERE occurred_at > current_timestamp - INTERVAL '7' DAY`

Also add a one-line type note at the same canonical: **`parse_datetime` returns `timestamp(3) with time zone`; `date_parse` returns a plain `timestamp(3)`** — pick based on whether downstream math needs tz awareness.

**2. (OPTIONAL, low) map_agg duplicate-key one-liner** at the map_agg canonical: "`map_agg` errors on duplicate keys within a group (`Duplicate map key`); if keys can repeat, dedup first or use `multimap_agg`." Did NOT bite here (premise guarantees uniqueness) — reactive-only, add only if a future map_agg probe with possible dup keys fails.

**3. DO NOT:** touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe this iter); rewrite the Q1 regexp_replace / Q3 map_agg / Q4 array_agg canonicals (clean); add `::`-casts (iter571 PIN); add EXTRACT(EPOCH) (iter562 ban); add QUALIFY; assert the 2-arg `regexp_replace` does anything other than global-remove; bump training/state.json (already 614); git commit/push.

## Fabrications / slips
- **NONE fabricated.** Every function is real Trino 467, correctly chosen: `regexp_replace` 2-arg remove, `parse_datetime` (Joda), `date_parse` (MySQL), `map_agg`, `array_agg`, `array_agg(... ORDER BY ...)`, `element_at`, `map_filter`. `\D` claim is TRUE.
- **One real slip:** Q2 form-1 alias-in-WHERE (INVALID-CLAUSE-PLACEMENT — SELECT alias referenced in WHERE). Diagnosed above; iter615 directive #1 addresses it at the responder's landing point.
- No `::`-cast, no wrong-function-choice, no format-string-mismatch (date_parse/parse_datetime dialects correctly matched), no off-by-one, no operator-precedence error, no wrong-version pin.

## Docs verified today
- trino.io/docs/467/functions/regexp.html — `regexp_replace(string, pattern) → varchar` "Removes every instance..." (Q1); Java pattern syntax → `\D` supported.
- trino.io/docs/467/functions/datetime.html — `date_parse(string, format) → timestamp(3)` MySQL specifiers (%i minutes, %S seconds, %Y, %H); `parse_datetime(string, format) → timestamp with time zone` Joda (Q2).
- trino.io/docs/467/sql/select.html — ORDER BY evaluated after GROUP BY/HAVING (sees aliases); WHERE precedes SELECT projection (Q2 alias scoping).
- trinodb/trino #16533 — alias-in-GROUP-BY unsupported, same scoping basis for alias-in-WHERE (Q2).
- trino.io/docs/467/functions/aggregate.html — `map_agg(key, value) → map<K,V>` (Q3); `array_agg(x) → array`, `array_agg(x ORDER BY y)` (Q4).

**OVERALL: 4.6875 PASS — Q1 regexp_replace 2-arg strip-non-digits clean (new canonical landed, `\D` claim true); Q2 parse functions + format strings correct but FORM 1's `WHERE occurred_at > ...` references the SELECT alias = INVALID Trino 467 (form 2 clean) — iter615 add alias-in-WHERE guardrail at the parse-timestamp canonical; Q3 map_agg clean (dup-key caveat reactive-only); Q4 array_agg + ORDER-BY-inside clean; federation NOT probed, row stays 4.49944/310.**
