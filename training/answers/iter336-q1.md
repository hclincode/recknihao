# Answer to Q1: Session Property Manager JSON Format (Iter 336)

**No, the format you found is not correct.** The JSON structure you showed will cause a parse error on Trino coordinator startup because it doesn't match the real session property manager schema.

## The correct format

The session property manager config is a **top-level JSON array** of match-rule objects — not an object with `defaultSessionProperties` and `sessionPropertySpecs` keys. Here's the correct structure:

```json
[
  {
    "group": "global\\.free_tier",
    "sessionProperties": {
      "query_max_execution_time": "60s"
    }
  },
  {
    "group": "global\\.enterprise_tier",
    "sessionProperties": {
      "query_max_execution_time": "30m"
    }
  }
]
```

## Key differences from what you found

1. **It's an array**, not an object with wrapper keys. The entire file starts with `[` and ends with `]`.
2. No `defaultSessionProperties` — there is no default wrapper in the JSON file itself. If a query matches no rule, Trino falls back to the cluster-wide `query.max-execution-time` property set in `config.properties` instead.
3. No `sessionPropertySpecs` key — rules are just array elements.
4. **Match fields go directly on the rule object** — `group`, `user`, `source`, `queryType`, `clientTags` are all top-level keys on each rule, alongside `sessionProperties`.

## Important details for your setup

- **The `group` field is a Java regex**, so the dot must be escaped: `global\\.free_tier` (not `global.free_tier`). An unescaped dot matches *any* character and will cause unexpected matches.
- You can use two properties for time limits:
  - `query_max_execution_time` — time from when the query *starts executing*. Queries exceeding this are killed with `EXCEEDED_TIME_LIMIT`.
  - `query_max_run_time` — time from when the query is *submitted* (includes queue wait). Usually set longer as a backstop.
- **Coordinator restart required** — changes to the JSON file only take effect when Trino restarts.

## Configuration files needed

1. `etc/session-property-config.properties`:
   ```properties
   session-property-config.configuration-manager=file
   session-property-manager.config-file=etc/session-property-manager.json
   ```

2. `etc/session-property-manager.json` — the array of rules shown above.

This should parse without errors. If you still get a parse error, double-check that the file is valid JSON (no trailing commas, proper quote escaping) and that the `group` regex has properly escaped dots.

**Resources cited:** `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md`
