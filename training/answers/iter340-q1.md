# Answer to Q1: Session Property Manager vs Resource Groups — What Actually Enforces Limits (Iter 340)

## The Short Answer

You've discovered a critical distinction: **the session property manager is just a default-setter, not an enforcer.** Your `SET SESSION query_max_execution_time = '2h'` worked because Trino allows clients to override session properties after they're set. The session property manager can't prevent that override — it only assigns an initial default value.

To actually lock down those limits so free-tier customers can't bypass them, you need **two separate mechanisms working together**:

1. **Session property manager** sets the initial defaults (e.g., free-tier gets 5 minutes)
2. **OPA (Open Policy Agent) access control rules** block the `SetSystemSessionProperty` action for non-admin users

Without both pieces, you only have defaults, not ceilings.

---

## Why Session Property Manager Alone Fails

The session property manager (`etc/session-property-manager.json`) works like this:

1. It reads your config file at Trino startup
2. When a free-tier query starts, it assigns `query_max_execution_time = 5m` to that session
3. But if the client runs `SET SESSION query_max_execution_time = '2h'`, that new value **replaces** the manager's default for the rest of the session
4. Trino treats them identically: the last value written wins, and `SET SESSION` writes last

Think of it like a form with a pre-filled field — you can change the pre-filled value whenever you want. The session property manager fills in the form, but it has no power to lock the field.

---

## Resource Groups Do Something Different (But Not for Time Limits)

This is the source of your confusion. Resource groups (`etc/resource-groups.json`) enforce **hard ceilings** on:
- `hardConcurrencyLimit` (number of queries running at once)
- `softMemoryLimit` (memory per group)
- `hardCpuLimit` / `softCpuLimit` (CPU budget per rolling window)

These ARE enforced by Trino's admission controller at query submission time, and there's no `SET SESSION` property that can raise them. A free-tier tenant with `hardConcurrencyLimit: 5` cannot submit a 6th concurrent query, period.

But time limits (`query_max_execution_time`, `query_max_run_time`) are **not** part of resource groups. They're session properties, and that's why `SET SESSION` can override them.

---

## What Actually Stops a Query from Running Over the Time Limit

Once you properly lock it down with OPA, here's what happens:

1. Your session property manager assigns `query_max_execution_time = 5m` to the free-tier session
2. The free-tier client **tries** to run `SET SESSION query_max_execution_time = '2h'`
3. OPA's `SetSystemSessionProperty` deny rule intercepts this action **before** the session state changes
4. OPA rejects the `SET SESSION` statement with `Access Denied`
5. The session keeps the manager-assigned 5-minute default

If the query later exceeds 5 minutes of actual execution time, Trino kills it with error code `EXCEEDED_TIME_LIMIT`.

---

## The Mental Model (Key Takeaway)

| Part | What it enforces | Can SET SESSION bypass it? | Example |
|---|---|---|---|
| **Resource groups** | Concurrency, memory, CPU | **NO** — these are not session properties | Free tier can't run 6 queries at once, no matter what they try |
| **Session property manager alone** | Time limits (defaults only) | **YES** — session properties are client-settable | Free tier's 5-min default gets overridden to 2h if you don't block it |
| **Session property manager + OPA rule** | Time limits (effectively enforced) | **NO** — OPA blocks the `SET SESSION` action itself | Free tier's 5-min default cannot be overridden; if they try, OPA says "Access Denied" |

The key insight: **resource groups = hard ceilings; session properties = defaults unless you add OPA to turn them into de-facto ceilings.**

---

## How to Lock It Down: Add the OPA Rule

Add a deny rule for the `SetSystemSessionProperty` OPA action for non-admin users. The action name is exact: `SetSystemSessionProperty` (for system-level properties like `query_max_execution_time`). For connector-scoped properties like `iceberg.split_size`, the action is `SetCatalogSessionProperty`.

Important: **whitelist your admin/ops/on-call principals** so your internal tooling can still run long compaction jobs without getting blocked.

## What to Do Next

1. Create your `etc/session-property-manager.json` with defaults per tier
2. Add an OPA deny rule for `SetSystemSessionProperty` for free-tier principals
3. Whitelist admin/ops principals in that OPA rule
4. Test it: connect as a free-tier user and verify `SET SESSION query_max_execution_time = '2h'` fails with `Access Denied`

**Resources cited:** `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md`
