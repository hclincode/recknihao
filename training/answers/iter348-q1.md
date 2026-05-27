# Answer to Q1: Trino Selector Regex Substring-Match Footgun (Iter 348)

You're hitting the core behavior of Java regex's `find()` method, which is how Trino evaluates the `user` field in resource-group selectors.

## The problem

When you write `"user": "data"`, Trino treats this as a Java regular expression and searches for it **anywhere as a substring** within the username. The regex doesn't require the entire username to be `data` — it just looks for the pattern appearing somewhere in the string. So:

- `data_science_alice` contains `data` → **matches**
- `data_engineering_bob` contains `data` → **matches**
- A user literally named `data` → **matches**

This is `Matcher.find()` behavior, not `Matcher.matches()` behavior. If you need exact matching, you must **anchor the regex with `^` (start) and `$` (end)**.

## The fix

Change your selector from:

```json
{ "user": "data", "group": "global.data_team" }
```

To:

```json
{ "user": "^data$", "group": "global.data_team" }
```

The anchors force the regex to match the entire username string, not just a substring. Now `data` matches, but `data_science_alice` and `data_engineering_bob` do not.

## If you want to match the whole data team by pattern

Be explicit with anchors and wildcards:

```json
{ "user": "^data_science_.*$", "group": "global.data_science" }
{ "user": "^data_engineering_.*$", "group": "global.data_engineering" }
```

Or, better for stable teams: use `userGroup` instead (requires configuring a group provider):

```json
{ "userGroup": "^data_team$", "group": "global.data_team" }
```

This applies to ALL selector fields that use Java regex: `user`, `originalUser`, `authenticatedUser`, `userGroup`, and `source`. The same substring-match footgun affects all of them — always anchor with `^...$` when you want exact matching.

## Verification

To confirm which resource group a query actually landed in:

```sql
SELECT query_id, user, resource_group_id
FROM system.runtime.queries
WHERE user LIKE 'data%'
ORDER BY created DESC
LIMIT 10;
```

The `resource_group_id` column shows the actual routing path. If users are landing in the wrong group, compare the resource_group_id to your expected group and trace which selector matched.

**Resources cited:** `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md`
