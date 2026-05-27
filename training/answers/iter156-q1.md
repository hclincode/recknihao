# Iter 156 Q1 — OPA Column Masking in Trino

## Answer

## How OPA Controls Data Access in Your Trino Setup

OPA does **both** things, but in a specific order:

1. **First**, OPA decides whether a query is allowed to run at all
2. **Then**, if allowed, OPA can automatically rewrite the query to mask specific columns before Trino fetches data from MinIO

### The Two Modes of OPA Control

**Allow/Deny Mode** (gates entire queries):
OPA receives every query your internal teams submit to Trino and answers: "Is user X allowed to read table Y?" If no, the query is rejected with `Access Denied` and never touches MinIO. This is the gatekeeping layer.

**Column-Masking Mode** (transforms data in flight):
This is where the PII masking happens. OPA doesn't just allow/deny the query — it returns a SQL expression that Trino **substitutes for the column** at query analysis time, before data leaves Trino. For example, instead of returning the raw `email` column, Trino executes something like:

```sql
-- What the analytics team typed:
SELECT user_id, event_type, email FROM events;

-- What Trino actually executes (OPA-injected transformation):
SELECT user_id, event_type, '****@****.com' FROM events;
```

This happens **inside Trino's query engine**, not at MinIO. The raw email never leaves Trino when an analytics user queries it.

### How Column Masking Is Configured

In your `etc/access-control.properties` on the Trino coordinator:

```properties
access-control.name=opa
opa.policy.uri=http://opa:8181/v1/data/trino/allow
opa.policy.column-masking-uri=http://opa:8181/v1/data/trino/columnMask
```

OPA returns a JSON response for each masked column, like:

```json
{"expression": "'****@****.com'"}
```

or for hashing:

```json
{"expression": "to_hex(sha256(to_utf8(email)))"}
```

Trino substitutes that SQL expression directly into the query before execution. The `opa.policy.column-masking-uri` endpoint is the key addition — without it, OPA only does allow/deny, not data transformation.

### Defense in Depth

Your setup will have three layers:

1. **OPA allow/deny policy**: Before the query even reaches the table, OPA checks: "Is this principal allowed to query this table?" This is your first gate.

2. **OPA column masking**: For tables the analytics team IS allowed to touch, OPA rewrites sensitive columns to masked versions so the raw PII never leaves the engine.

3. **View-level isolation**: If you use Trino views for the analytics team, the view itself can point them at pre-aggregated or pre-masked data entirely.

### Critical Point: Where Masking Happens vs MinIO

The masking happens **inside Trino's query execution engine**, not at the MinIO layer:

- **Support team** (raw access): they connect to Trino, OPA allows the query without masking → they get raw emails from MinIO.
- **Analytics team**: they connect to Trino, OPA allows the query but applies column masking → Trino substitutes the masked expression *before* fetching from MinIO, so the raw email never travels from MinIO to the caller.

MinIO itself doesn't know about masking — it's purely a Trino security feature. If someone bypassed Trino and accessed MinIO directly, they'd see raw data. That's why network controls to prevent direct MinIO access from non-admin teams are also necessary.

### What OPA Needs to Know

Your OPA policy defines:

- Which roles can query the `events` table unmasked (support team)
- Which roles get column masking applied (analytics team)
- What the masking expression is for each sensitive column (`email`, `phone_number`, etc.)

The masking policy is written in OPA's Rego language and lives in your OPA server — it's not configured in Trino directly. Trino just calls the OPA endpoint and applies whatever SQL expression OPA returns.
