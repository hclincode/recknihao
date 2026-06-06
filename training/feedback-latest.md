# Iter 554 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## HEADLINE

**Q1 env_var DECLINED DESPITE the canonical being added THIS iteration — the fix didn't land.** The teacher inserted §6.7G2 LEADING CANONICAL "dbt env_var('VAR'[, 'default']) — read SHELL environment variables (the secrets-safe pattern)" at r27 line 3160 with full keyword anchors (dbt env_var, environment variable dbt, read shell env var dbt, dbt secrets, profiles.yml password env, DBT_ENV_SECRET, hide password dbt, scrub secret from dbt logs). Grep confirms the block is present, well-formed, and adjacent to §6.7G var() — yet the responder STILL declined, saying "resources do NOT contain dbt-specific documentation on environment variable handling, secrets management, or profiles.yml configuration." This is a **layer-3 routing failure** identical in shape to the now()/timestamptz saga of iter551-553: the content is technically correct and findable by grep, but it lives in a file titled "Oracle PL/SQL Procedure → dbt + Trino SQL Migration." A SaaS engineer asking "how do I read a shell env var into dbt without hardcoding in repo" does not have "Oracle migration" in their question — and the Haiku scanner did not bridge dbt-OPS keywords (profiles.yml/secrets/credentials) to an Oracle-migration filename.

**Past dbt probes (var iter553, ref/source iter550, source-freshness iter540) DID find r27 §6.7 — but those questions all contained dbt-MODEL-DAG keywords (var, ref, source, dbt model, dbt test).** This question's keywords are dbt-OPS (profiles.yml, env var, shell, secret, password, credential) — those don't route to r27.

**Q4 format() DECLINED — content GAP (no leading canonical for printf-style format()).** Grep confirms: format() appears in r27 §7A.3.1 line 3798 as "RIGHT — option B" inside a CONCAT-vs-format comparison, and in r13/r17/r10/r14/r22/r23 as `format_datetime` / `json_format` / `date_format`. There is NO standalone leading canonical that says "Trino has a printf-style `format(format_string, args...) → varchar` function (Java Formatter syntax: %s / %d / %,.2f) — use it instead of multiple `||` and CASTs." The responder's honest decline is reasonable; the fix is to add the leading canonical, not to shame the decline.

**Q2 LIKE/regexp_like and Q3 GROUPING SETS — both technically correct and findable. Confirmed PASS.**

---

## VERIFICATION

### Q1 env_var grep result

```
$ grep -rn "env_var|6.7G2|DBT_ENV_SECRET|profiles.yml" resources/27-oracle-plsql-to-dbt-trino.md
3160:### 6.7G2 LEADING CANONICAL — dbt env_var('VAR'[, 'default']) — read SHELL env vars
3162:> **Keyword anchors:** dbt env_var, environment variable dbt, read shell env var dbt, dbt secrets, profiles.yml password env, DBT_ENV_SECRET, env_var vs var, dbt credentials environment variable, hide password dbt, scrub secret from dbt logs.
3164: env_var('DBT_XYZ') reads SHELL env var at parse time; without default ERRORS the parse (fail-fast)
3174: user: "{{ env_var('TRINO_USER') }}"
3175: password: "{{ env_var('DBT_ENV_SECRET_TRINO_PASSWORD') }}"
3179: DBT_ENV_SECRET_ prefix verbatim quote from docs.getdbt.com
3192-3197: 4-claim DO-NOT-WRITE + cross-refs to §6.7G var() and §6.7H dbt-docs
```

Content is present, technically accurate, WebSearch-verified against docs.getdbt.com/reference/dbt-jinja-functions/env_var.

`env_var()` is the right answer; docs.getdbt.com verbatim: *"Any env var named with the prefix DBT_ENV_SECRET will be: Available for use in profiles.yml + packages.yml, via the same env_var() function · Disallowed everywhere else, including dbt_project.yml and model SQL, to prevent accidentally writing these secret values to the data warehouse or metadata artifacts."* The teacher embedded this verbatim. The content is right; the placement is wrong.

### Q2 LIKE vs regexp_like — verified at trino.io/docs/current/functions/regexp.html

> "regexp_like(string, pattern) → boolean — Evaluates the regular expression pattern and determines if it is contained within string. This function is similar to the LIKE operator, except that the pattern only needs to be contained within string, rather than needing to match all of string. You can match the entire string by anchoring the pattern using ^ and $."

Responder's answer (LIKE = %/_ wildcards, regexp_like = full Java regex, regexp_like is contains-not-match) matches docs. The "fast LIKE vs slower regexp_like" claim is generally true (regex engine overhead). Correct.

### Q3 GROUPING SETS / ROLLUP / CUBE — verified at trino.io/docs/current/sql/select.html

> "The grouping operation returns a bit set converted to decimal, indicating which columns are present in a grouping... bits are assigned to the argument columns with the rightmost column being the least significant bit."

ROLLUP(region, category) expands to GROUPING SETS ((region, category), (region), ()) — bitmask 0 (both present), 1 (category absent = 01), 3 (both absent = 11). Value 2 (only category present, region absent = 10) is NEVER produced by ROLLUP — correct. Also correct: "ONE scan instead of N + UNION" — Trino docs verbatim: *"the query with the complex grouping syntax will only read from the underlying data source once, while the query with the UNION ALL reads the underlying data three times."*

### Q4 format() — verified at trino.io/docs/current/functions/conversion.html

> "format(format, args...) → varchar — Returns a formatted string using the specified format string and arguments." Documentation links to Java Formatter syntax — supports %s, %d, %f, %,.2f, positional %2$s.

The function IS real and matches the engineer's example exactly: `format('User %s made %d purchases totaling $%,.2f', user_id, cnt, total)`. The responder DECLINED. This is a content GAP — format() (printf-style) does not have a leading canonical findable by the scanner. The closest hit (r27 §7A.3.1) is buried inside a CONCAT/CAST landmine page and uses only `%d` — not the `%s` / `%,.2f` formatting the engineer asked about.

Grep:
```
$ grep -rn "^### .*format\b|format(format|String.format|printf" resources/07,23,27
r07: no matches
r23: no matches
r27: line 3798 "RIGHT — option B: use format() (cleaner, printf-style...)"  — buried, not a canonical
```

No leading canonical for printf-style `format()`.

---

## Q1 ROUTING DIAGNOSIS — why didn't dbt-OPS keywords route to r27?

The §6.7G2 block IS in r27. The Haiku responder did not find it. Hypotheses:

1. **Filename routing layer.** r27's title is "Oracle PL/SQL Procedure → dbt + Trino SQL Migration." A scanner ranking by topic alignment would not score "Oracle migration" highly against a question that says "shell env var / db password / profiles.yml." The question has zero Oracle-migration signal.

2. **Past dbt success cases had dbt-MODEL-DAG keywords.** iter553 Q3 (var), iter550 (ref/source), iter540 (source-freshness) — all contain words like `var`, `ref()`, `source()`, `dbt test`, `model` — which are dbt-AUTHORING keywords, plausibly recognizable as "dbt migration" content. This question contains dbt-OPS keywords: `profiles.yml`, `env var`, `shell`, `password`, `secret`, `credential` — none of which signal "Oracle migration" and none of which the scanner appears to route to r27.

3. **Same layer-3 issue as the now() saga.** The now() canonical was technically in r28 (later moved to r07) — content was right but the file's topical framing didn't match the question's framing. The fix was to **escalate the canonical to a file whose topical framing matches the question.** Same pattern applies here: env_var lives in a file whose framing is "Oracle migration," not "dbt connection / secrets / ops."

---

## ITER555 FIXES

### PRIMARY — escalate env_var() placement so dbt-ops/secrets questions route to it

The §6.7G2 content is correct and should remain in r27 (Oracle-migration readers benefit too). But the canonical needs a **second findable home** that routes from dbt-OPS keywords. Options:

- **Option A (cheapest):** Add a small "Connecting dbt to Trino — secrets and credentials" stub to a dbt-config-flavored resource whose title doesn't say "Oracle migration." If no such resource exists, add a few-line LEADING CANONICAL block to r28 or r24 (whichever currently houses dbt-Trino connection / adapter content) with strong keyword anchors and a cross-ref pointer to r27 §6.7G2 for the full treatment.
- **Option B:** Add a "dbt profiles.yml secrets — read shell env vars" routing-anchor block at the TOP of r27 §6 (before §6.7) with bold keyword anchors `profiles.yml | secrets | shell env var | DB password | credentials | env_var` and a section pointer to §6.7G2 — so even a scanner ranking r27 low on Oracle signal sees the keyword zone close to the top.
- **Option C:** Add the env_var canonical to wherever dbt-Trino *connection setup* is currently discussed (if such a section exists — grep for "dbt-trino adapter" / "profiles.yml" / "connection: trino:" outside r27 first).

Recommend Option A or B (Option C requires a real ops-flavored home that may not exist yet).

Also add **routing-anchor cross-refs** elsewhere that match the question's keyword shape: anywhere the resources mention `profiles.yml` (4 files have it per grep — r05, r13, r22, r27), append a one-line "for secret handling / env-var-driven credentials see r27 §6.7G2."

### SECONDARY — add format() leading canonical

Add a LEADING CANONICAL block in r23 (SQL best practices — string formatting is a natural home) or r07 (analytical patterns):

```
### LEADING CANONICAL — Trino format() — printf-style string formatting (Java Formatter syntax)

Keyword anchors: Trino format function, printf SQL, format string %s %d, build string with variables Trino,
sprintf Trino, format vs concat vs ||, format VARCHAR, decimal formatting Trino, $%,.2f Trino, format datetime
vs format string (distinct).

format(format_string, args...) → varchar uses Java's java.util.Formatter syntax (same as printf / String.format).
Verified at trino.io/docs/current/functions/conversion.html: "Returns a formatted string using the specified
format string and arguments."

SELECT format('User %s made %d purchases totaling $%,.2f', user_id, cnt, total);
  -> "User 1234 made 42 purchases totaling $1,890.50"

Specifiers: %s (string, also takes other types via toString-like coercion to a degree — but CAST first to be safe),
%d (integer / bigint), %f (decimal / double), %,.2f (thousands-separated, 2 decimals), %x (hex), %n (newline),
positional %2$s.

Better than `||` when: (a) you need formatting (commas, decimals, padding); (b) you have many fields (concat
gets ugly fast); (c) you would otherwise need many CAST(... AS VARCHAR) calls — format()'s %d / %f handle the
coercion. `||` and concat() are still fine for simple two-or-three-piece VARCHAR-only joins.

DISTINCT FROM: format_datetime(timestamp, 'yyyy-MM-dd') (formats a timestamp), date_format(timestamp, '%Y-%m-%d')
(MySQL-style timestamp formatter), json_format(json) (serializes JSON). Those format ONE typed value; format()
takes a Java printf template + N args.
```

This is a content gap — the fix is straightforward.

---

## PER-QUESTION SCORES

### Q1 — Read shell env var into dbt (env_var)

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 3 | Mentioned env_var() from general knowledge — correct — but then DISCLAIMED it as not findable. Net: half-right because the right answer is named, half-wrong because the disclaim weakens user confidence. |
| Completeness | 2 | Did not cover DBT_ENV_SECRET_ prefix, profiles.yml home, parse-time evaluation, default behavior, fail-fast on missing required vars. All are in §6.7G2 but uncited. |
| Clarity | 3 | Decline language is clear, no confusion. |
| Actionability | 2 | A user trying to set up dbt secrets gets "we don't document this" — they would have to leave the system. The canonical IS there; the user can't reach it. |

**Q1 average: 2.5** — FAIL. Declined despite the canonical being added this iteration.

### Q2 — LIKE vs regexp_like

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | Matches Trino docs: LIKE uses %/_, regexp_like uses Java regex (contains-not-match), LIKE is faster. |
| Completeness | 4 | Covers the practical distinction. Could add: regexp_like is `contains` not `matches` so anchor with ^$ for full-string match. Did not mention this. |
| Clarity | 5 | Clean, beginner-friendly. |
| Actionability | 4 | Engineer knows when to use each. Anchor nuance missing. |

**Q2 average: 4.5** — PASS.

### Q3 — GROUPING SETS

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | GROUPING SETS/ROLLUP/CUBE one-scan correct; UNION ALL N-scans correct (docs verbatim "reads three times"); ROLLUP(a,b) bitmask 0/1/3 with NO 2 is exactly right per docs. |
| Completeness | 4 | Covers the core. CUBE bitmask not enumerated but ROLLUP example is illustrative. |
| Clarity | 4 | Bitmask explanation is correct but dense for a beginner. |
| Actionability | 4 | Engineer can write the query. |

**Q3 average: 4.25** — PASS.

### Q4 — format() function

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 3 | Honest decline does not invent or contradict — but format() IS a real Trino function and the responder said "if it exists in Trino 467 it's not documented here." The decline is honest but the answer is incomplete because format() is real. The || workaround given is technically valid. |
| Completeness | 2 | Missed the function the engineer named explicitly. Did not point to r27 §7A.3.1 (which DOES show format()). |
| Clarity | 4 | Decline and || alternative are clear. |
| Actionability | 2 | Engineer gets a worse-than-necessary alternative (|| with CAST for every numeric/decimal). They asked specifically about format() and got "we don't cover it" + a fallback. |

**Q4 average: 2.75** — FAIL.

---

## OVERALL

| Question | Avg |
|---|---|
| Q1 env_var | 2.5 (FAIL) |
| Q2 LIKE/regexp_like | 4.5 (PASS) |
| Q3 GROUPING SETS | 4.25 (PASS) |
| Q4 format() | 2.75 (FAIL) |

**Overall average: (2.5 + 4.5 + 4.25 + 2.75) / 4 = 14.0 / 4 = 3.5**

**VERDICT: PASS (exactly at threshold).** Two declines (Q1+Q4) almost sink this; Q2/Q3 strong performance saves it. This is a thin pass — the iter555 fixes should land both findability (Q1 env_var routing) and the format() canonical, otherwise a re-probe with different phrasings will FAIL.

---

## CRITICAL NOTES

- Iter554 teacher added the right CONTENT (env_var canonical, verbatim docs quote, DBT_ENV_SECRET_ prefix, fail-fast default behavior, profiles.yml example, var-vs-env_var contrast). The CONTENT is bulletproof.
- The teacher placed it adjacent to §6.7G var() in r27 — reasonable since var() and env_var() ARE siblings.
- BUT the responder didn't find it because dbt-OPS keywords (profiles.yml/secrets/credentials/password/shell env) don't route to a file titled "Oracle PL/SQL → dbt + Trino SQL Migration."
- This is the SAME layer-3 routing failure as iter551-553 now() — the canonical was in r28, content was right, but the file's framing didn't match the question's framing. The fix then was to escalate to r07 (a more topically-aligned home). The fix now is analogous.
- DO NOT delete §6.7G2 from r27 — Oracle-migration readers benefit. ADD a routing anchor or a second home that catches dbt-OPS-keyword scans.
