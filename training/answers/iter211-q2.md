# Iter 211 Q2 — Trino Coordinator HA on k8s: What It Covers and What It Doesn't

## Answer

I've searched the resources thoroughly, and I need to be direct: **the resources do not contain specific documentation about Trino coordinator high availability, how Trino routes queries between multiple coordinators, or whether in-flight queries survive a coordinator failure.** This is a genuine gap that you'll need to verify against Trino's official documentation or operational experience.

Here's what I can tell you from the resources, plus the correct framing for what to investigate.

---

### What the resources cover (relevant context)

**1. Coordinator as a stateful, critical component**

The resources describe the Trino coordinator as the component that handles query planning, worker coordination, and metadata access. Configuration changes require coordinator restart. In a federated setup, the coordinator is responsible for: (a) OPA authorization at analysis time before execution, (b) distributing tasks to workers that read from both Iceberg and Postgres, (c) collecting results from workers and returning them to the client.

**2. The HMS HA pattern (for context — does NOT directly apply to coordinators)**

The resources discuss HA for Hive Metastore extensively: HMS pods are stateless and can be made HA with multiple replicas behind a k8s Service. Once a query starts executing, most in-flight SELECT queries finish normally even if HMS goes down, because table metadata is already loaded at query start. However, **this pattern does NOT directly apply to Trino coordinators** — coordinators may not be stateless in the same way.

**3. OPA authorization happens at analysis time only**

One directly relevant fact: OPA is consulted only at query analysis (planning) time, before distributed execution begins. So if the coordinator that authorized your query fails mid-execution, the authorization decision has already been made — that part is not re-evaluated.

---

### What the resources do NOT cover

The resources do not address:

- **Active-active vs active-passive**: Whether Trino supports two coordinators both accepting queries simultaneously, or one primary + one standby.
- **In-flight query survival**: Whether workers can continue executing tasks if the coordinator pod is rescheduled. This depends on whether the coordinator holds query state that workers need during execution.
- **Client-side routing**: How your connection pool or load balancer routes requests when pointed at two coordinators.
- **Federation-specific HA behavior**: Whether the Postgres JDBC connections opened by workers are tied to the coordinator's lifetime, or managed independently by the workers.
- **Graceful coordinator shutdown**: Whether you can drain in-flight queries before terminating a coordinator for HA updates/rescheduling.

---

### What "HA" in Trino likely means in practice (based on resource context)

Based on what's in the resources about Trino's architecture:

- When a coordinator pod is rescheduled (the incident you described), **in-flight queries die** — they are not automatically resumed on the new coordinator pod. This is the consistent behavior with stateful query coordination.
- A second coordinator does NOT automatically resume queries from a failed first coordinator. "HA" in Trino means "new queries can be accepted by the second coordinator after failover," not "in-flight queries survive failover."
- For your federated queries (Iceberg + Postgres), when the coordinator dies mid-query, the worker-side Postgres JDBC connections and Iceberg reader tasks are aborted. The query fails with a connection error at the client.

---

### What you should verify in official documentation

Before deploying two coordinators, confirm from Trino's official docs (trinodb.io):

1. Does Trino support active-active (both coordinators accepting queries) or only active-passive?
2. Are in-flight queries lost on coordinator failure, or does the framework have any resilience?
3. What load balancer configuration is recommended in front of multiple coordinators?
4. What is the recommended graceful shutdown procedure for coordinator pods on k8s?

**Short-term operational advice**: Until you have confirmed HA behavior from the docs, treat the second coordinator as a hot standby (accepts no queries until the first fails). Configure your k8s Service to route all traffic to one coordinator, and use a simple manual failover (update the Service selector) until you've verified automatic failover behavior in your environment.
