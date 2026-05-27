# Production Environment Information

> This file describes the production environments where the `weak-ai-responder` will be deployed and where the SaaS engineer's product runs.
> The teacher and judge must read this file before writing resources or evaluating answers — all advice must fit these environments.

---

## Target serving environment (weak-ai-responder)

*(To be filled in by the repo owner)*

- Model:
- Context window limit:
- Deployment platform:
- Any tool or API constraints:

---

## Production environment (SaaS product and data team)

- **Deployment**: On-premises data center only — no public cloud. All services must run on-prem.
- **Orchestration**: Spark, Trino, and the SaaS product all run in a Kubernetes (k8s) cluster on-prem.
- **Object storage**: Bare-metal MinIO, accessed via S3 protocol.
- **Ingestion stack**: Apache Spark with Iceberg 1.5.2, backed by Hive Metastore (ingestion use only).
- **Query engine**: Trino 467 with the Iceberg connector, backed by Hive Metastore.
- **Transformation**: dbt is supported and permitted for users.
- **Ad-hoc result export**: Users sometimes run `INSERT INTO <temp_table> AS SELECT ...` and then download the result files directly from MinIO to speed up query performance.
- **Spooling**: Experimental for query workloads; not officially supported or provided to users.

### Authentication and authorization

- **Authentication**: Custom authentication service using **JWT tokens**. Users obtain a JWT from the auth service; Trino validates it via a custom JWT authenticator configured in `etc/config.properties`. Standard username/password and LDAP are NOT used.
- **Authorization (Trino)**: **Open Policy Agent (OPA)** with a customized policy set is the authorization backend for Trino. The OPA plugin evaluates every Trino query action against the centralized policy. File-based access control rules (the default examples in resources/) are provided only as conceptual illustrations — they do NOT reflect the production setup.
- **SaaS user permission model**: User permissions within the SaaS product are governed by an **external governance document** that is not included in this repository. Resources in this repo should not attempt to document specific permission rules or role hierarchies — those are defined externally.

### Implications for answering permission-related questions

When a SaaS engineer asks about access control, role assignment, or user permission enforcement specific to this environment:
- Answer with **general/conceptual Trino RBAC knowledge** (how roles work, how OPA integrates with Trino at a high level).
- State clearly that **specific permission rules and user governance are defined in an external document** not yet available in this repo, and that detailed governance guidance will be provided in a future external document.
- Do NOT attempt to write specific OPA policies, role hierarchies, or permission rules — defer those to the external governance document.

---

## Notes for agents

- **Teacher**: All resources you write must give advice that works within the above constraints. Do not recommend tools or architectures that are incompatible with the production stack described here. For authentication/authorization: resources may explain general Trino RBAC and OPA concepts, but must not document specific policies or role hierarchies — those belong in the external governance document. When the stack is not yet filled in, note that assumption explicitly in your resources.
- **Judge**: Evaluate answers not just for technical correctness but for fit with this production environment. For auth/authz questions: a correct answer gives general Trino/OPA concepts and defers specific permission rules to the external governance document. An answer that invents specific policy rules or tries to document the permission model is out of scope.
- **Weak-ai-responder**: When answering, always consider whether the advice applies to the production environment described here. For authentication questions: mention JWT and OPA as the production mechanism at a conceptual level; tell the engineer that specific permission rules are in an external governance document not yet available in this repo. Do not attempt to write OPA policies or specific role assignments.
