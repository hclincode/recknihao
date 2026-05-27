# Iter 348 Q1 Score — Multi-tenant analytics: Trino selector regex match semantics

## Question recap
User claims their selector `"user": "data"` is matching `data_science_alice` and `data_engineering_bob` and asks why a pattern like `'data'` matches usernames containing `data` in the middle.

## Score table

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 1.5 | Central claim is **factually wrong**. Trino 467's `StaticSelector.java` uses `Matcher.matches()` (full-string match), NOT `Matcher.find()` (substring search) for `userRegex`, `userGroupRegex`, and `sourceRegex`. With `.matches()`, `"user": "data"` would NOT match `data_science_alice`. Responder confidently asserts the opposite. Anchor advice (`^...$`) is harmless but unnecessary — anchoring a `.matches()` pattern doesn't change behavior. The diagnostic SQL query and selector field list are correct; the `userGroup` alternative recommendation is sound. Score reflects: correct structure, correct ancillary advice, but the load-bearing technical mechanism is wrong. |
| Beginner clarity | 4.5 | Clear, well-structured, good before/after JSON examples, plain-language explanation of what regex anchors do. No unexplained jargon. The only clarity issue is that the explanation is clear and convincing but explaining a false mechanism. |
| Practical applicability | 2.5 | The "fix" (`^data$`) will work for the symptom IF the symptom is real, but only by accident (it happens to be a valid full-string match). The diagnostic query (`system.runtime.queries`) is genuinely useful. However, the answer fails to consider that the user's stated symptom is **impossible** under correct Trino behavior — a senior engineer should have asked "are you sure your selector is literally `data` and not `data.*` or `.*data.*`?" or noted that another selector higher in the array might be the actual matcher. Engineer will apply the fix and may see it work, but won't understand the real cause. |
| Completeness | 3.0 | Addresses the question as posed, covers all selector fields (user/originalUser/authenticatedUser/userGroup/source), gives a verification recipe, and points to userGroup as a more stable alternative. Missing: any consideration that the symptom as described may not be reproducible, that a higher-priority selector might be matching first, or that the user's config might actually contain wildcards they didn't notice. |
| **Average** | **2.875** | **FAIL** (below 3.5 threshold) |

## What Worked
- Clean structure: problem → fix → broader-applicability → verification.
- Correct JSON syntax in all snippets.
- Correct list of regex-bearing selector fields (`user`, `originalUser`, `authenticatedUser`, `userGroup`, `source`).
- Correct recommendation to prefer `userGroup` for stable team membership.
- Correct columns in the `system.runtime.queries` diagnostic query (`user`, `resource_group_id`).
- Good citation back to `resources/05`.

## What Missed
- **Central technical mechanism is wrong.** Trino 467's `StaticSelector.match()` uses `Matcher.matches()` (full-string match) for user/userGroup/source regex evaluation, not `Matcher.find()`. The `.find()` call exists ONLY in `addVariableValues()`, which runs AFTER the `.matches()` gate has already validated full-string match, and only extracts named capture groups for template expansion. The match/reject decision is `.matches()`-based.
- Because the mechanism explanation is wrong, the "fix" reasoning is wrong: adding `^...$` to a `.matches()` pattern has no behavioral effect — `matches()` already requires the pattern to match the entire input. The fix is harmless but the rationale is wrong.
- Did not challenge the user's premise. The reported symptom (`"user": "data"` matching `data_science_alice`) is **not possible** if the config literally contains the regex `data` and the selector actually fires. A correct answer would have offered the real possibilities: (a) the user wrote `"user": "data.*"` or `"user": ".*data.*"` and is misremembering, (b) a higher-priority selector with a broader pattern is matching first (first-match-wins), (c) the user is looking at a different selector than they think, or (d) the `data_science_alice` user is matching a different selector entirely.
- This is a **dangerous failure mode**: the engineer will leave with a confident but incorrect mental model and won't recognize the real bug if it happens again with a different shape.

## Technical Accuracy Verification (WebSearch)

Verified against Trino source code via WebFetch on `raw.githubusercontent.com/trinodb/trino/467/plugin/trino-resource-group-managers/src/main/java/io/trino/plugin/resourcegroups/StaticSelector.java`:

| Claim in answer | Actual Trino 467 behavior | Verdict |
|---|---|---|
| "Trino evaluates `user` field with `Matcher.find()` (substring)" | `userMatcher.matches()` — full-string match | **WRONG** |
| `"user": "data"` matches `data_science_alice` | NOT a full-string match → selector returns `Optional.empty()` → does NOT match | **WRONG** |
| Anchor with `^...$` for exact matching | Harmless but unnecessary — `.matches()` already requires full-string | **MISLEADING** (gives the impression anchoring is needed when it is not) |
| Same behavior applies to `user`, `originalUser`, `authenticatedUser`, `userGroup`, `source` | All five fields ARE Java regex fields; all use `.matches()` (full-string) for the match decision | Correct list of fields, wrong about the match method |
| `system.runtime.queries` columns `user`, `resource_group_id` | Confirmed present | Correct |

Source code excerpts verified (Trino 467, `StaticSelector.java`):

```java
// Lines ~87-89:
Matcher userMatcher = userRegex.get().matcher(criteria.getUser());
if (!userMatcher.matches()) { return Optional.empty(); }

// Line ~97:
if (userGroupRegex.isPresent() && criteria.getUserGroups().stream()
        .noneMatch(group -> userGroupRegex.get().matcher(group).matches())) {
    return Optional.empty();
}

// Lines ~101-103:
if (!sourceRegex.get().matcher(source).matches()) {
    return Optional.empty();
}
```

`Matcher.find()` only appears inside `addVariableValues()`, which extracts named capture groups for template expansion AFTER the match gate has already passed. It is NOT part of the match/reject decision.

## Resource Fix Applied (REQUIRED)

`resources/05-multi-tenant-analytics.md` contains the same factually-incorrect claim in multiple places that needs teacher fix:

- **Line 2346**: "Selector regexes use Java `find()`, not `matches()` — substring matches by default." → **WRONG**. Should say: "Trino's resource-group selectors use `Matcher.matches()` (full-string match), not `find()`. A bare regex like `user: \"data\"` matches ONLY a user literally named `data`, NOT `data_science_alice` or `metadata`. To intentionally match a substring or prefix, use explicit wildcards: `user: \"data.*\"` matches anything starting with `data`; `user: \".*data.*\"` matches anything containing `data`."
- **Line 2397**: Same incorrect claim ("All four of these selector fields are Java regexes evaluated with `Matcher.find()`, not `Matcher.matches()`") — needs the same correction.
- The "anchor with `^...$`" advice is harmless redundancy; it should be removed or reframed as "the default `.matches()` behavior already requires full-string match — you do NOT need to add `^...$`."

This is a long-standing resource error that has been propagated through many iterations and never caught by judges (rubric history shows the substring-match footgun being repeated as fact since at least iter 333). The teacher must correct resources/05 before the next iteration covers this topic.

The user's reported symptom in this question is, in fact, **impossible** as stated — and the responder's job (with corrected resources) would be to walk the user through the real possibilities: a wildcard they didn't notice in their config, a higher-priority selector matching first, or a misread of which selector fired.

## Rubric Update

- Multi-tenant analytics: isolating customer data in SaaS
- Prior: 4.460 / 139 questions
- This Q: 2.875
- New running avg: (4.460 × 139 + 2.875) / 140 = (619.94 + 2.875) / 140 = 622.815 / 140 = **4.449 / 140 questions**
- Status: **PASSED** (still above 3.5 threshold despite the fail, due to large denominator) — but a critical resource gap is now exposed and must be fixed before this topic can continue accruing reliable scores.

## Sources
- [Trino StaticSelector.java (release 467) — full-string `.matches()` confirmed](https://github.com/trinodb/trino/blob/467/plugin/trino-resource-group-managers/src/main/java/io/trino/plugin/resourcegroups/StaticSelector.java)
- [Trino PR #3023 — original userGroup regex implementation, uses `.matches()`](https://github.com/trinodb/trino/pull/3023)
- [Trino PR #24662 — originalUser/authenticatedUser selectors, same `.matches()` pattern](https://github.com/trinodb/trino/pull/24662)
- [Trino Resource Groups documentation (current)](https://trino.io/docs/current/admin/resource-groups.html)
