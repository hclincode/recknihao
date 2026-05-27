# Answer to Q2: Resource Group Selector Matching — First-Match-Wins (Iter 344)

**Yes, it's strictly first-match-wins.** Trino evaluates your `selectors` array top-to-bottom, tests each selector's conditions against the query, and stops at the first one where all conditions pass. There is no scoring, no most-specific-wins, no combining of multiple selectors. The moment it finds a match, it assigns the query to that group and ignores everything below.

Think of it as an if-elif-else chain:

```
if (selector[0] conditions all match) → assign to selector[0].group, DONE
elif (selector[1] conditions all match) → assign to selector[1].group, DONE
...
else → no match (query fails)
```

## Why enterprise queries are landing in the catch-all

**Most likely cause: the catch-all rule is ABOVE the enterprise rule in your JSON file.**

A catch-all selector has no conditions — it matches every query automatically. If it appears before your enterprise rule, it wins for every query, and the enterprise rule below it is dead code.

Wrong order (catch-all first):
```json
"selectors": [
  { "group": "global" },                              // matches EVERYTHING — catch-all runs first
  { "user": "acme-.*", "group": "global.enterprise" } // never reached
]
```

Correct order (specific rule first):
```json
"selectors": [
  { "user": "acme-.*", "group": "global.enterprise" }, // enterprise queries match here
  { "group": "global" }                                  // catch-all for everyone else
]
```

## Other causes of intermittent failures

If your enterprise rule IS above the catch-all but still occasionally fails, the `user` regex isn't matching:

**1. The regex doesn't match the actual JWT principal**

The `"user"` field matches against the JWT principal decoded from the auth token — not a role or group name. Check what the actual JWT principal value is:

```sql
SELECT query_id, user, resource_group_id
FROM system.runtime.queries
ORDER BY created DESC
LIMIT 20;
```

If your selector says `"user": "enterprise-tenant-id"` but the `user` column shows `"acme-prod"`, that's your mismatch. Update the selector regex to match what the JWT actually contains.

**2. Multiple conditions require ALL to match (AND logic)**

If your selector has both `user` and `source` fields, BOTH must match for the selector to fire. If one fails, Trino moves to the next selector:

```json
{ "user": "acme-.*", "source": "dashboard", "group": "global.enterprise" }
```

This only matches queries where the JWT principal matches `acme-.*` AND the source string is exactly `"dashboard"`. An enterprise query submitted from an API (source = `"api"`) falls through to the catch-all.

## The five operational rules

1. **Order is everything** — specific rules go first, catch-all goes last
2. **First match stops evaluation** — no scoring, no combining
3. **All fields in one selector are AND-combined** — all must match for the selector to fire
4. **`user` and `source` are Java regexes** — `"acme"` matches any string containing "acme"; `"^acme$"` matches exactly "acme"
5. **`group` in selectors is a literal string** — no regex, no escaping needed

## Quick debugging steps

1. Check your JSON file — is the enterprise selector above the catch-all?
2. Run the `system.runtime.queries` query above and look at the `user` and `resource_group_id` columns for recent enterprise queries
3. If `resource_group_id` shows the catch-all group, copy the exact `user` value shown and update your selector regex to match it

**Resources cited:** `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md`
