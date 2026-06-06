# Judge feedback — iter555 (EXTENDED PHASE)

**Overall: 3.6875 / 5.00 — THIN PASS (overall-average rule, >=3.5). Two declines (Q1+Q4) drag the average; Q2 + Q3 saved the iteration.**

| Q | Accuracy | Completeness | Clarity | Actionability | Avg | Verdict |
|---|---|---|---|---|---|---|
| Q1 dbt env_var / profiles.yml password | 3 | 1 | 3 | 1 | **2.00** | THIRD DECLINE — ROUTING STILL BROKEN |
| Q2 Trino format() printf | 5 | 5 | 5 | 5 | **5.00** | WIN — gap closed |
| Q3 dbt snapshots SCD2 + deleted source | 5 | 5 | 5 | 5 | **5.00** | WIN |
| Q4 Trino named WINDOW clause | 4 | 1 | 4 | 2 | **2.75** | HONEST DECLINE — content gap |

---

## HEADLINE — Q1 THIRD-decline routing diagnosis

The responder declined Q1 for the **THIRD consecutive iteration** (iter553, 554, 555). Verbatim:

> "I don't have enough information... resources do not contain specific guidance on env vars in dbt profiles.yml. I found credential patterns — `${ENV:VARIABLE_NAME}` for Trino ITSELF (Kubernetes configs, Trino federation catalogs) — but not dbt profiles.yml specifically."

This response **precisely identifies the routing failure** the teacher's iter555 fix did NOT address:

1. **The §6.7G2 env_var canonical IS present in r27** at line 3180 — content is bulletproof (signature, DBT_ENV_SECRET_ prefix, profiles.yml worked example, vs var() table, DO-NOT-WRITE table).
2. **The §6.7 routing anchor IS present** at line 2182 — a 12-row Q-keywords -> canonical map with `dbt profiles.yml`, `profiles.yml password`, `dbt connection`, `DBT_ENV_SECRET`, `dbt secrets`, etc.
3. **BUT the routing anchor lives UNDER a section header that reads "### 6.7 dbt tests to add (replacing Oracle EXCEPTION handlers)"** (line 2180).

**The Haiku responder, scanning resource headers for keyword matches to a "store my dbt password safely" question, does NOT open a section titled "dbt tests to add" — because "tests" is the wrong semantic anchor for a "secrets/connection/password" question.** Instead, the responder's keyword scan finds `${ENV:APP_PG_PASSWORD}` in **r22 federation catalogs** (lines 188, 285, 417, 1352, 1725) and **r13 ingestion** (Spark JDBC + Debezium credentials, lines 1881–1885). Both are Trino-SERVER / Spark-JDBC credentials, NOT dbt — so the responder correctly says "I found credential patterns but not dbt profiles.yml specifically" and declines.

**The routing anchor is invisible because it lives behind a "tests" header that a "secrets" question would never open.** The iter554 judge correctly diagnosed Layer-3 routing failure, but iter555's fix (a routing anchor INSIDE the "tests" section) did not address the underlying problem — it just added more text under a header that's still semantically mismatched. **The dbt-OPS routing anchor cannot live under a "tests" header. It needs its own connection/secrets-named home.**

### iter556 PRIMARY FIX (Q1 routing — be specific)

**Promote the env_var/profiles.yml canonical OUT of the "dbt tests" section into a standalone section whose header NAMES the question topic.** Required structure:

```markdown
## 6.X dbt CONNECTION & SECRETS (profiles.yml / env_var / DBT_ENV_SECRET_)
### 6.X.1 LEADING CANONICAL — dbt profiles.yml + env_var() — store passwords as shell env vars, NOT plaintext
### 6.X.2 LEADING CANONICAL — DBT_ENV_SECRET_ prefix — auto-scrub secrets from dbt logs
```

Key requirements for the teacher:

1. **The section HEADER MUST contain the exact question keywords** the responder is scanning for: `profiles.yml`, `password`, `secrets`, `credentials`, `connection`. Do NOT bury under "dbt tests" / "Oracle migration" / "dbt OPS" / any generic name.
2. **Keep the iter554/555 §6.7G2 body content verbatim** — it is correct. Just MOVE it to a section whose header NAMES dbt CONNECTION/PROFILES/SECRETS.
3. **Reconcile in place** — DELETE the §6.7G2 block from §6.7 after moving (do NOT leave duplicates). Update the §6.7 routing anchor with a cross-reference: `§6.X — see new dbt connection & secrets section above`.
4. **Position the new section EARLY in r27** (before §6 "Worked end-to-end example" at line 1989) — so a TOC scan hits it before any migration-specific content.
5. **Do NOT edit r22.** The federation row (4.49944/310) is locked.

WebSearch re-verified the env_var content is correct at [docs.getdbt.com/reference/dbt-jinja-functions/env_var](https://docs.getdbt.com/reference/dbt-jinja-functions/env_var) and [docs.getdbt.com/docs/build/environment-variables](https://docs.getdbt.com/docs/build/environment-variables):
- "If you want a particular environment variable to be scrubbed from all logs and error messages, in addition to obfuscating the value in dbt, you can prefix the key with `DBT_ENV_SECRET_`."
- "Secret env vars are scrubbed from dbt logs and replaced with `*****`, any time their value appears in those logs (even if the env var was not called directly)"
- "`password: \"{{ env_var('DBT_PASSWORD') }}\"`" — canonical profiles.yml pattern.

**Content is right. Routing is wrong. The fix is STRUCTURAL — a new section header — not content.**

---

## Q4 SECONDARY FIX — named WINDOW clause gap

Trino supports the SQL standard named `WINDOW` clause (since Trino 352). Per [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html):

> "In Trino, windows can be specified in two ways: by a reference to a named window specification defined in the WINDOW clause, or by an in-line window specification."
> Example: `WINDOW w AS (PARTITION BY custkey ORDER BY orderdate RANGE BETWEEN interval '1' month PRECEDING AND CURRENT ROW)`

**Grep confirmed ZERO findable canonical** in r07 (analytical-query-patterns), r23 (sql-best-practices), or any other resource for `WINDOW w AS` / "named window" / "OVER w". The responder correctly declined a real feature — that's a CONTENT gap, NOT a fabrication. The Accuracy score stays at 4 (honest decline, no fabrication); Completeness tanks because the feature exists and is widely used.

### iter556 fix (Q4)

Add a LEADING CANONICAL block in **r07 §window-functions** (analytical-query-patterns is the natural home for OVER patterns). Suggested:

```markdown
### LEADING CANONICAL — Trino named WINDOW clause — define a window once, reference by name
> Keyword anchors: named window Trino, WINDOW clause SQL, define window once, WINDOW w AS, OVER w, reuse window spec, partition by once, repeat OVER (PARTITION BY).
> Verified at [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html).

**The pattern.** Instead of repeating `(PARTITION BY tenant_id ORDER BY event_ts ROWS BETWEEN ...)` after every window function, define it once at the end of the SELECT:

SELECT
  user_id,
  ROW_NUMBER() OVER w     AS rn,
  LAG(event_ts) OVER w    AS prev_ts,
  SUM(amount) OVER w      AS running_total
FROM events
WHERE tenant_id = 42
WINDOW w AS (
  PARTITION BY user_id
  ORDER BY event_ts
  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
);

Supported since Trino 352 (March 2021). Windows can also extend named windows: `WINDOW w2 AS (w ORDER BY amount DESC)`.
```

Cross-reference from r23 (sql-best-practices — "avoid repeating OVER clauses") and r28 (complex-sql-perf — readability of large window queries).

---

## Q2 + Q3 — WINS (LOCK THEM)

**Q2 format() — gap closed.** The iter555 r23 LEADING CANONICAL (between §3.1A string-split and §3.1B SUM(DECIMAL)) works. Responder answered `format('User %s spent $%,.2f', user_id, total_spent)`, listed `%s/%,.2f/%%/%d/%05d/%.1f%%`, distinguished from format_datetime/date_format, and recommended over `||` chains. Verified at [trino.io/docs/current/functions/string.html](https://trino.io/docs/current/functions/string.html) — `format(format_string, args...) -> varchar`, Java Formatter syntax. **Do NOT edit r23 §format() canonical.**

**Q3 dbt snapshots — solid.** Responder correctly listed the 4 default metadata cols (`dbt_scd_id` / `dbt_updated_at` / `dbt_valid_from` / `dbt_valid_to`), the point-in-time pattern (`dbt_valid_from <= X AND (dbt_valid_to IS NULL OR > X)`), the deleted-source-row-not-auto-closed behavior, and the `hard_deletes='new_record'` config that adds `dbt_is_deleted`. Timestamp-vs-check strategy distinction correct. r09 §SCD2 (lines 350–435) is the canonical home; routing worked.

---

## Iteration verdict

- Overall: **3.6875 — THIN PASS** by overall-average rule (>=3.5).
- Pattern: 2 strong WINs (Q2 + Q3 at 5.00) carrying 2 declines (Q1 at 2.00, Q4 at 2.75). **Without the Q3 cushion this would FAIL.** Q1 has now declined THREE iterations running despite TWO teacher attempts to fix routing — the iter555 fix put routing anchors INSIDE the wrong-named section.
- **iter556 priority**:
  - PRIMARY: Q1 STRUCTURAL fix — move env_var canonical out of "dbt tests" section into a section whose header NAMES connection/profiles/secrets. Header text matters more than body content.
  - SECONDARY: Q4 named WINDOW canonical in r07.
  - Q2 + Q3 are LOCKED — do NOT edit.
- **Federation row 4.49944/310 — do NOT touch.** r22 untouched.
