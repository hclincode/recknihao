# Iter 209 Q1 — OPA Mid-Query Deny: What Happens to In-Flight Federated Queries

## Answer

I've searched the resources carefully for information about OPA mid-query behavior and Postgres connection handling. Here's what I can tell you from the production stack documentation:

### What we know about OPA authorization timing

OPA authorization is evaluated **after SQL parsing but before execution**. Specifically, when Trino receives a query:

1. It parses the SQL into an abstract syntax tree (AST)
2. It runs the analysis phase, where the access control plugin (OPA in your case) is consulted for each table and column referenced
3. **Only if every authorization check passes** does the query proceed to execution

Trino rejects unauthorized queries at the coordinator with an `Access Denied` error before any data is touched in storage.

### What the resources do NOT specify

**The resources do not document what happens to a query that is already running (past the analysis phase) if OPA policy changes or OPA itself fails.** This is the core of your question and it's not covered in the available materials.

### What we know about query cancellation generally

The resources do document that Trino can cancel running queries (via `CALL system.runtime.kill_query()`), and when a query is cancelled:

- The coordinator marks the query as `FAILED`
- A cancel signal is sent to every worker running the query's tasks
- Memory and CPU slots are freed
- In-flight JDBC reads are aborted

But this describes **intentional** cancellation via the kill procedure, not what happens if an authorization layer fails or changes during execution.

### JDBC/Postgres connection behavior under socket timeouts

The resources describe what happens when JDBC connections encounter problems at the driver layer. If a JDBC socket times out (e.g., `java.net.SocketTimeoutException: Read timed out`), the JDBC client gives up waiting, but this is a **socket-level failure**, not an authorization check.

### Bottom line for your on-call scenario

Based on the resources, I can tell you:

1. **Policy denial before query starts**: If OPA denies a query during the analysis phase, Trino rejects it cleanly with `Access Denied` before the query touches Postgres.

2. **Mid-query policy changes / OPA service down**: The resources do not specify the behavior if OPA becomes unavailable *after* a query has started executing, or if policy changes are pushed while a query is mid-execution. This is a gap in the documentation that your on-call situation requires clarification on.

3. **Postgres connections**: OSS Trino 467 has no native connection pooling to Postgres (per the resources), so each query opens direct JDBC connections. If those connections hang, you could accumulate zombie connections — but the resources don't specify whether OPA failures or policy changes would trigger that condition.

For your actual on-call readiness, you'll need clarification from your platform team on:

- OPA service dependency during query execution (is every query continuously authorized, or only at the start?)
- Whether OPA bundle updates take effect immediately on new queries only, or somehow affect running queries
- Your deployed OPA configuration — specifically whether it's a sidecar (in-process, unlikely to fail) or a separate service pod
