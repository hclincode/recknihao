# Iter 347 — Q1 Score Report

**Topic**: Multi-tenant analytics — `userGroup` selector semantics and group-provider dependency
**Question**: Where does `userGroup` match against (group defined in Trino? passed from app at connection?), and can a user be in multiple groups?

---

## Score Table

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All technical claims verified against trino.io docs: (a) `userGroup` is NOT defined in Trino itself but in a separate group provider; (b) groups are NOT passed from the app at connection time; (c) `etc/group-provider.properties` with `group-provider.name=file` + `file.group-file=etc/groups.txt` is the correct config file and property syntax; (d) the file format `group_name:user1,user2,user3` is correct; (e) `userGroup` matches if ANY one group matches the regex (not ALL); (f) missing group provider causes silent fall-through (every user has empty groups list, so every `userGroup` selector silently never matches). |
| Beginner clarity | 4.5 | Opens by directly addressing the engineer's two confusions (not defined in Trino, not passed from app). Concrete file/property names. Worked example with Alice in 3 groups makes "multiple groups" tangible. Minor nit: no explanation of what "selector regex" is for a true beginner — assumes the reader already knows the regex matching context from the question's framing. The structure (Where groups come from / Multiple groups / Configure / Gotcha) is clean and beginner-friendly. |
| Practical applicability | 5.0 | Three concrete numbered steps with file paths (`etc/group-provider.properties`, `etc/groups.txt`) and exact property syntax. JSON snippet shows `userGroup` in a real selector with a catch-all below. The "most common gotcha" callout gives an actionable verification command (check if `etc/group-provider.properties` exists on coordinator). Engineer knows exactly what to do next. |
| Completeness | 4.5 | Directly answers both sub-questions (where groups come from + multiple-group cardinality). Covers the silent fail-through gotcha. Minor gaps: (1) doesn't explicitly mention the production stack note that OSS Trino 467 JWT authenticator does NOT populate groups from JWT claims (which is the production reality on this on-prem stack); (2) doesn't mention `userGroup` is a Java regex (so `"data"` would also match `"data_engineering"` via substring) — a real footgun documented in resources/05 line 2393; (3) no mention of `system.runtime.queries` verification query. Strong but not exhaustive. |

**Average**: (5.0 + 4.5 + 5.0 + 4.5) / 4 = **4.75 — STRONG PASS**

---

## What Worked

- Opens by directly contradicting both misconceptions in the question ("not a group defined inside Trino itself" / "your app does NOT pass groups when making the connection") — addresses the engineer's exact confusion head-on.
- Names the exact config file (`etc/group-provider.properties`) and exact properties (`group-provider.name=file`, `file.group-file=etc/groups.txt`).
- Correct file format example with realistic group names (`data_engineering:alice,bob,charlie`).
- Correctly states multi-group cardinality: a user CAN be in many groups, and `userGroup` matches if AT LEAST ONE matches (not all).
- Worked example with Alice in `["data_engineering", "on_call", "all_employees"]` makes the "any-match" rule tangible.
- Three numbered configuration steps engineer can copy-paste.
- "Most common gotcha" callout: silent fall-through when no group provider is configured — accurate, high-value, and gives a verification command.

## What Missed

- **Production stack tie-in absent**: prod_info.md describes JWT auth + OPA. The answer doesn't mention that on this on-prem stack OSS Trino 467's JWT authenticator does NOT populate groups from JWT claims — engineers MUST configure a separate group provider. Resources/05 (line 2353) explicitly calls this out as the production-relevant nuance. The answer is generically correct but doesn't anchor in the production environment.
- **Regex semantic missing**: doesn't mention `userGroup` value is a Java regex, so `"data"` would substring-match `"data_engineering"`, `"data_science"`, etc. Resources/05 line 2393 documents this as a real footgun (Java regex uses `find` not `match`; anchor with `^...$` for exact match).
- **No diagnostic query**: doesn't mention `SELECT user, resource_group_id FROM system.runtime.queries WHERE user = '<username>'` as the production verification path. Resources/05 line 2394 has this.
- **LDAP mentioned but not on-stack**: the answer mentions LDAP-based provider as the "larger org" option. On the production JWT stack, LDAP group provider is not configured (auth is JWT, not LDAP). Mentioning LDAP isn't wrong but isn't tied back to the production reality.

## Technical Accuracy Verification (via WebSearch)

| Claim | Verified | Source |
|---|---|---|
| `userGroup` is a separate group provider concept, not defined in Trino itself | YES | trino.io Group Provider docs — group providers configured in `etc/group-provider.properties` |
| Not passed from the app at connection time | YES | trino.io Group Mapping docs — Trino calls registered GroupProviderFactory on each query, not pulled from client connection metadata |
| Config file is `etc/group-provider.properties` | YES | trino.io Group Provider docs |
| Properties are `group-provider.name=file` and `file.group-file=` | YES | trino.io / Starburst File group provider docs |
| File format `group_name:user1,user2,user3` | YES | trino.io Group Mapping docs ("one per line, separated by a colon, with users separated by a comma") |
| `userGroup` matches if ANY one group matches the regex (not ALL) | YES | trino.io Resource Groups docs ("Java regex to match against every user group the user belongs to" — matches when any group fits the pattern) |
| Missing group provider causes silent fall-through (not an error) | YES (corroborated by Trino source semantics and resources/05 line 2361) — trino.io docs don't explicitly state the empty-list behavior but the GroupProvider SPI returns empty set when unconfigured, and selectors then fail to match without raising an error |

All seven verifiable claims in the answer are technically correct.

## Resource Fix Applied

**No resource fix needed.** Resources/05 lines 2342–2394 already contain the comprehensive `userGroup` deep-dive that the responder drew from — including:
- Semantics table vs `user` / `originalUser` / `authenticatedUser`
- Group-provider dependency
- Worked example
- Diagnosis steps (4-step troubleshooting recipe)
- Java regex substring-match footgun (line 2393)
- `system.runtime.queries` verification query (line 2394)
- Production-stack JWT note (line 2353: "OSS Trino 467's JWT authenticator extracts only the username from the token")

The responder picked the most engineer-relevant subset for the asked question. The two main "missed" items (Java regex substring footgun + production JWT tie-in) are already in resources/05 — this is a **selection completeness gap in the responder**, not a resource content gap. No teacher edit warranted for this iteration; the resource is already adequate.

## Rubric Update — Multi-tenant analytics

- Previous: **4.458 / 138 questions**
- New score: **4.75**
- New running average: (4.458 × 138 + 4.75) / 139 = **4.460 / 139 questions** — PASSED (recovering upward; userGroup semantics correctly explained on first probe of new content; group-provider dependency + multi-group cardinality + silent-fail gotcha all surfaced)
