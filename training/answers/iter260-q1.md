# Iter260 Q1 — Join Pushdown: Does Trino Pull Both Postgres Tables Separately?

## Answer

You've identified exactly the right concern, and the good news is: **Trino CAN push joins between the two Postgres tables back to Postgres itself**, avoiding the costly scenario you're worried about. However, your cross-catalog join (Postgres + Iceberg) follows a completely different pattern. Let me explain both.

### 1. Intra-Catalog Joins (Postgres-to-Postgres): Yes, They Push Down

When you join `app_pg.public.users` to `app_pg.public.subscriptions`, Trino does NOT pull both tables into memory and join them on Trino workers. Instead, **join pushdown** rewrites your query into a single SQL statement and sends it to Postgres:

```sql
-- What you write in Trino:
SELECT u.id, u.email, s.plan
FROM app_pg.public.users u
JOIN app_pg.public.subscriptions s ON s.user_id = u.id
WHERE u.tenant_id = 42;

-- What Postgres actually receives (rewritten by Trino):
SELECT u.id, u.email, s.plan
FROM public.users u
INNER JOIN public.subscriptions s ON s.user_id = u.id
WHERE u.tenant_id = 42;
```

Postgres then joins the tables using its own indexes and join algorithms — exactly the efficient server-side join you want. Trino receives already-joined rows back, not raw Postgres data.

### 2. Cross-Catalog Joins (Postgres + Iceberg): Always in Trino

The moment your query joins the Postgres result to your Iceberg events table, the join itself **always** executes on Trino workers — it never pushes to Postgres or Iceberg. This is a structural limitation, not a tuning knob:

```sql
-- This is always a cross-catalog join (Postgres + Iceberg):
SELECT u.id, s.plan, e.event_type
FROM app_pg.public.users u
JOIN app_pg.public.subscriptions s ON s.user_id = u.id
JOIN iceberg.analytics.events e ON e.user_id = u.id
WHERE u.tenant_id = 42;

-- Execution flow in Trino:
-- 1. Postgres join (users ⋈ subscriptions) pushes to Postgres ✓
-- 2. Trino pulls the result from Postgres
-- 3. Trino scans Iceberg events with dynamic filtering (the small user_id list)
-- 4. Trino hash-joins the Postgres result to the Iceberg result on workers
```

Why? Postgres doesn't know what an Iceberg table is, and Iceberg doesn't know what a Postgres table is. There is no shared execution model. **There is no "cross-catalog join pushdown" feature in Trino — it does not exist and cannot exist.**

### 3. How to Verify: EXPLAIN Signatures

Never assume join pushdown fired. Use `EXPLAIN (TYPE DISTRIBUTED)` to check. The signature lives in the **query plan tree shape**:

#### Join Pushed Down (Intra-Catalog Success)
You see **ONE `TableScan` node** with a synthetic query handle, and **NO `InnerJoin` or `HashJoin` operator**:

```
Output
└── TableScan[app_pg:Query[SELECT ... FROM users u INNER JOIN subscriptions s ON ... WHERE ...]]
    constraint: tenant_id = 42
```

This means Postgres received a single JOIN statement and returned pre-joined rows.

#### Join NOT Pushed Down (or Failed)
You see **TWO `TableScan` nodes** with an `InnerJoin` / `HashJoin` operator above them:

```
Output
└── InnerJoin[user_id = id][Distribution: REPLICATED]
    ├── TableScan[app_pg.public.users]
    │   constraint: tenant_id = 42
    └── TableScan[app_pg.public.subscriptions]
```

This means Postgres returned each table separately, and Trino did the hash join in memory.

#### Cross-Catalog Join (Always This Shape)
A join between Postgres and Iceberg always looks like the "failed pushdown" shape above, but the two `TableScan` nodes come from different catalogs. This is expected and correct — not a failure.

**Absolute truth check:** Query `pg_stat_activity` during execution. If join pushdown succeeded, you'll see one SQL statement with `JOIN` in it. If it failed, you'll see two separate `SELECT` statements (one per table) issued nearly simultaneously.

### 4. Configuration: Two Session Properties Control Intra-Catalog Join Pushdown

For same-catalog joins only — these do NOT affect cross-catalog joins:

#### `<catalog>.join_pushdown_enabled` (Default: `true`)

Controls whether intra-catalog join pushdown is allowed at all:

```sql
-- Force the join to run on Trino workers instead (for debugging):
SET SESSION app_pg.join_pushdown_enabled = false;

-- Allow it again:
SET SESSION app_pg.join_pushdown_enabled = true;
```

#### `<catalog>.join_pushdown_strategy` (Default: `AUTOMATIC`)

Controls how aggressively Trino pushes intra-catalog joins:

**`AUTOMATIC`** (the default):
- Trino's cost-based optimizer (CBO) reads Postgres table statistics (`pg_stats`) via JDBC
- The CBO estimates whether the join is cheaper in Postgres or on Trino workers
- Only pushes if it decides Postgres wins
- **Requires that you've run native PostgreSQL `ANALYZE`** on the Postgres primary so that `pg_stats` has NDV and null-fraction statistics
- If stats are missing, the CBO may decline pushdown even for same-catalog joins

**`EAGER`**:
- Push down whenever structurally possible, **no statistics required**
- Does not consult the cost model at all
- Correct choice when you KNOW both tables are in the same Postgres catalog AND Postgres has indexes on the join keys

Example:
```sql
-- Use EAGER strategy for this query:
SET SESSION app_pg.join_pushdown_strategy = 'EAGER';

SELECT u.id, s.plan
FROM app_pg.public.users u
JOIN app_pg.public.subscriptions s ON s.user_id = u.id
WHERE u.tenant_id = 42;
```

### 5. Why Intra-Catalog Pushdown Sometimes Doesn't Fire (Debugging Checklist)

If you expect join pushdown but `EXPLAIN` shows two `TableScan` nodes under an `InnerJoin`:

1. **Missing PostgreSQL statistics** (most common under `AUTOMATIC`):
   - Run `ANALYZE billing.users; ANALYZE billing.subscriptions;` on the Postgres **primary** (not the replica, which is read-only)
   - Flush Trino's metadata cache: `CALL app_pg.system.flush_metadata_cache();`
   - Re-run the EXPLAIN

2. **Cost model is being conservative** (still under `AUTOMATIC`):
   - Use `EAGER` strategy instead: `SET SESSION app_pg.join_pushdown_strategy = 'EAGER';`

3. **Non-equi-join or function in the `ON` clause**:
   - Joins with `ON a.x = b.y` push; joins with `ON a.x = LOWER(b.y)` or `ON a.x < b.y` typically do not
   - Restructure to an equi-join if possible

4. **`join_pushdown_enabled` is explicitly set to `false`**:
   - Check your session: `SHOW SESSION LIKE 'app_pg.join_pushdown%';`
   - Check your catalog config file: `etc/catalog/app_pg.properties` — look for `join-pushdown.enabled=false`

**Important:** These session properties use **underscores** (`join_pushdown_enabled`), but the catalog `.properties` file uses **hyphens** (`join-pushdown.enabled`).

### 6. Property Names: Catalog File vs. Session

| Context | Property name | Example |
|---|---|---|
| Catalog `.properties` file (cluster default) | `join-pushdown.enabled` | `join-pushdown.enabled=true` |
| `SET SESSION` (per-session override) | `<catalog>.join_pushdown_enabled` | `SET SESSION app_pg.join_pushdown_enabled = false;` |
| Catalog `.properties` file (cluster default) | `join-pushdown.strategy` | `join-pushdown.strategy=EAGER` |
| `SET SESSION` (per-session override) | `<catalog>.join_pushdown_strategy` | `SET SESSION app_pg.join_pushdown_strategy = 'EAGER';` |

### 7. The Full Picture: Your Three-Table Query

```sql
SELECT u.id, u.email, s.plan, e.event_type
FROM app_pg.public.users u
JOIN app_pg.public.subscriptions s ON s.user_id = u.id
JOIN iceberg.analytics.events e ON e.user_id = u.id
WHERE u.tenant_id = 42;
```

**What happens:**
1. **`users ⋈ subscriptions`** (both in `app_pg`) — this join **pushes to Postgres** if you have stats and `AUTOMATIC` succeeds, or if you use `EAGER` strategy. Postgres joins them server-side and returns a smaller result.
2. Trino receives that joined result and the Iceberg connector scans the events table **with dynamic filtering** — Trino derives the user_id IN-list from the smaller Postgres join result and pushes it into the Iceberg scan, dramatically reducing the rows read.
3. **`(users ⋈ subscriptions) ⋈ events`** (Postgres result ⋈ Iceberg) — this cross-catalog join **always executes on Trino workers**, no way around it. But because dynamic filtering pruned the Iceberg side heavily, the join is fast.

**Bottom line:** Your Postgres-to-Postgres join is already optimized (if you've configured it right). Your Postgres-to-Iceberg join runs in Trino, which is the only option — but dynamic filtering makes it survivable. There is no way to tell Trino "push the cross-catalog join to Postgres" because that's architecturally impossible.
