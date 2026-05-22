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

---

## Notes for agents

- **Teacher**: All resources you write must give advice that works within the above constraints. Do not recommend tools or architectures that are incompatible with the production stack described here — this applies to both the SaaS product and the data team. When the stack is not yet filled in, note that assumption explicitly in your resources.
- **Judge**: Evaluate answers not just for technical correctness but for fit with this production environment (SaaS product side and data team side). An answer that is correct in general but wrong for this stack is a failure.
- **Weak-ai-responder**: When answering, always consider whether the advice applies to the production environment described here. If prod_info.md is incomplete, flag that your answer assumes a generic setup.
