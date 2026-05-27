# Iter250 Q1 — Dynamic Filtering Property Prefix Confusion

## Answer

Your problem is a **property naming mismatch** caused by a critical Trino rule that differs between catalog configuration files and SQL session properties. The bare `dynamic-filtering.wait-timeout` is being silently ignored in your Iceberg catalog because **Iceberg requires a connector-name prefix in the properties file**, but you're using the bare form. Additionally, the session property name uses **underscores instead of hyphens** and **your catalog name instead of the connector name**.

### Why the bare `dynamic-filtering.wait-timeout` is silently ignored

Iceberg (along with Hive and Delta Lake) is a **lakehouse connector** that requires the connector-name prefix for its connector-specific properties. In your `etc/catalog/iceberg.properties` file:

**Wrong (silently ignored):**
```properties
dynamic-filtering.wait-timeout=20s
```

**Correct (the prefix is REQUIRED):**
```properties
iceberg.dynamic-filtering.wait-timeout=20s
```

Trino does **not error** when you use the bare form — it simply does not apply the setting. Your EXPLAIN output looks the same because the default 1-second timeout is still in effect.

### The correct catalog property form

Add this line to `etc/catalog/iceberg.properties` (restart coordinator and workers for it to take effect):

```properties
iceberg.dynamic-filtering.wait-timeout=20s
```

The **`iceberg.` prefix is mandatory**. Without it, the property is silently ignored. This is different from JDBC connectors (PostgreSQL, MySQL) which use the bare form `dynamic-filtering.wait-timeout=30s` (no prefix needed).

### The correct session property form

For per-query tuning without a restart, use the session property form. Two naming differences from the catalog file:

1. **Use underscores, not hyphens**: the session property is `dynamic_filtering_wait_timeout`
2. **Use your actual catalog name, not the connector type**: if your Iceberg catalog file is named `iceberg.properties`, the catalog name is `iceberg`

**Correct:**
```sql
SET SESSION iceberg.dynamic_filtering_wait_timeout = '20s';
```

**Wrong (what you tried):**
```sql
SET SESSION dynamic_filtering_wait_timeout = '20s';
-- Fails: "Session property does not exist" — missing catalog prefix
```

### The general prefix rule for connector-specific catalog properties

| Connector type | Catalog properties file form | Session property form |
|---|---|---|
| **Lakehouse** (Iceberg, Hive, Delta) | **Prefix required**: `iceberg.dynamic-filtering.wait-timeout=20s` | **Catalog-name prefix, underscores**: `SET SESSION iceberg.dynamic_filtering_wait_timeout = '20s'` |
| **JDBC** (PostgreSQL, MySQL) | **Bare form**: `dynamic-filtering.wait-timeout=30s` | **Catalog-name prefix, underscores**: `SET SESSION app_pg.dynamic_filtering_wait_timeout = '30s'` |

The key insight: **lakehouse connectors require the connector-name prefix in properties files**. JDBC connectors use the bare form. But in **both cases, session properties require the catalog-name prefix and use underscores**.

### Why this matters for your scenario

You're setting the wait-timeout because Postgres (your small dimension table, the build side) needs time to hash before Iceberg (the probe side) starts scanning. The timeout that matters is the **Iceberg catalog's** — it controls how long Iceberg waits for the dynamic filter from Postgres before scanning without it. After adding the prefixed form and restarting, Iceberg will wait up to 20 seconds for Postgres to finish building the IN-list before launching an unfiltered scan.
