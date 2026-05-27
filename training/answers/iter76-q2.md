# Iter76 Q2 — Answer

**Question**: Postgres ENUM column `subscription_tier` synced to Iceberg — what type does it become, and what happens when a new enum value (`'team'`) is added to Postgres later?

---

## Answer

Both of your concerns have good news answers. The short version: Postgres ENUMs become VARCHAR in Iceberg, and adding a new enum value in Postgres is a non-event on the Iceberg side — no crash, no migration, no rewrite.

### What type does the ENUM become?

When Spark reads your `subscription_tier` column via JDBC from Postgres, the ENUM type is converted to **VARCHAR** (STRING in Spark/Hive notation). Postgres delivers ENUM values as plain text strings over the JDBC wire, and Spark maps them to `StringType`. Your Iceberg table ends up with `subscription_tier VARCHAR` — not a constrained enum, just a string column that happens to currently hold only three distinct values.

This is correct and normal. Iceberg has no enum type. VARCHAR is the right mapping.

**Does it matter for queries?** Not really. Parquet uses dictionary encoding for low-cardinality string columns automatically, so `GROUP BY subscription_tier` or `WHERE subscription_tier = 'pro'` is efficient without any special setup. You query it just like any string column in Trino:

```sql
SELECT subscription_tier, COUNT(*) AS users
FROM iceberg.analytics.subscriptions
WHERE tenant_id = 'acme'
GROUP BY subscription_tier;
```

### Adding `'team'` later — zero action needed on the Iceberg side

When `'team'` starts appearing in Postgres rows, your Spark sync job reads those rows from Postgres, sees `subscription_tier = 'team'`, and writes them into Iceberg as VARCHAR values — exactly the same as it writes `'free'` or `'pro'`. Nothing in Iceberg or Parquet constrains what string values a VARCHAR column can hold.

**The column definition does not change.** It is still `subscription_tier VARCHAR`. Old Parquet files contain rows with `'free'`, `'pro'`, `'enterprise'`. New Parquet files written after `'team'` launches contain rows with any of those values plus `'team'`. They coexist in the same Iceberg table with no schema migration.

This is different from Postgres, where adding a value to an ENUM type requires an `ALTER TYPE` DDL statement. In Iceberg, there is no equivalent — because there is no constraint to update.

**No rewrite of historical files is needed.** Iceberg's schema evolution handles column additions, renames, and type promotions — all as metadata-only operations. But you're not changing the schema here at all; you're just adding new values to an unconstrained string column. Historical files are untouched.

### What you do need to update

The Iceberg data layer requires no changes. But check your application code for hardcoded assumptions:

| Location | Risk |
|---|---|
| SQL CASE statements | `CASE subscription_tier WHEN 'free' THEN ... WHEN 'pro' THEN ... WHEN 'enterprise' THEN ... END` returns NULL for `'team'` rows — silently wrong |
| Dashboard filters | A filter for "all paying tiers" that hardcodes `IN ('pro', 'enterprise')` will miss `'team'` users |
| Ingestion validation | If your Spark job validates against a hardcoded allowed-values list before writing, it will reject `'team'` rows |

The Iceberg table itself is fine. The risk is in downstream SQL logic that assumed the column had only three values.

### Summary

| Concern | Answer |
|---|---|
| What type in Iceberg? | VARCHAR — Postgres ENUMs arrive as strings over JDBC |
| Sync job crashes when `'team'` appears? | No — VARCHAR accepts any string value |
| Historical Iceberg files need rewriting? | No — the schema does not change |
| Anything needed in Iceberg? | Nothing — no ALTER TABLE, no migration |
| What does need updating? | Application-level SQL and dashboards that assumed only 3 values |
