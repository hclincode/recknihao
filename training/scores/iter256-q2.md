# Iter256 Q2 Score

**Score: 4.9 / 5.0** — PASS (threshold: 4.5)

## What was correct
- Direct, unambiguous "yes" answer to the cross-catalog INSERT question with a concrete SQL example using fully-qualified `catalog.schema.table` names — exactly matches Trino's federation model.
- Three-phase lifecycle is correctly described: HMS registers intent at start, Parquet files staged invisibly during SELECT, atomic metadata-pointer swap on commit. This aligns with the Iceberg spec ("An atomic swap of one table metadata file for another provides the basis for serializable isolation").
- Failure mode reasoning is correct: if commit at phase 3 never fires, the `metadata_location` pointer stays on the pre-INSERT snapshot, the table is safe, but staged Parquet files become orphans.
- `ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d')` syntax is exactly right and matches the Trino docs example.
- 7-day minimum retention floor correctly identified (matches `iceberg.remove-orphan-files.min-retention` default, with the documented error "Retention specified is shorter than the minimum retention configured").
- Type-mapping table is solid: NUMERIC(p,s) precision/scale must match, JSONB → VARCHAR (Iceberg has no native JSON in the format versions in production use), ENUM → VARCHAR, TIMESTAMPTZ → TIMESTAMP(6) WITH TIME ZONE, UUID → UUID, BYTEA → VARBINARY are all correct.
- High-watermark incremental pattern with **pinned upper bound** for idempotency is the correct design pattern — explains *why* the upper bound matters (drift on retry).
- "When NOT to use this" section is honest and useful: >5M rows, mutable source (UPDATE/DELETE invisible to append-only watermark), and the per-table-not-cross-table atomicity caveat.
- Fits the production environment (Trino 467 + Iceberg + HMS + MinIO on k8s) — uses HMS as the commit authority, references object storage, no cloud-only tools recommended.

## Gaps or errors
- Minor: Iceberg format v3 introduced a native VARIANT type that can hold JSON-shaped data; the table says "JSONB → VARCHAR only" which is correct for the production v1/v2 environment but slightly overstated as an absolute. Not a deduction given the prod stack uses Iceberg 1.5.2.
- Minor imprecision: the answer says "HMS registers intent" before reading rows. In practice the Iceberg connector plans the write and acquires the base snapshot reference at planning; the *atomic* HMS interaction is the commit at the end. The conceptual framing is fine for a beginner but slightly conflates planning-time metadata reads with a "registration" step.
- The note about Iceberg VARCHAR "having no length limit" is true for Iceberg STRING but worth noting Trino exposes it as unbounded VARCHAR — a tiny clarification, not an error.

## WebSearch verification notes
- **trino.io/docs/current/connector/iceberg.html** + **/sql/insert.html**: Confirmed Trino supports `INSERT INTO catalog.schema.table SELECT ...` across catalogs in a single statement. Federation across multiple catalogs in one query is a documented core capability.
- **iceberg.apache.org/spec** (Reliability): Confirmed "atomic swap of one table metadata file for another provides the basis for serializable isolation" — the answer's three-phase description matches the spec.
- **trino.io Iceberg connector docs**: Confirmed `remove_orphan_files` procedure exists, default `iceberg.remove-orphan-files.min-retention` is `7d`, and shorter retention thresholds throw the documented error. The `ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d')` syntax in the answer is exactly as documented.
- **trino.io PostgreSQL connector docs**: Confirmed type mappings for NUMERIC, UUID, JSONB are handled by the connector. The answer's mappings are consistent with the documented behavior; JSONB → VARCHAR landing in Iceberg is correct for v1/v2 Iceberg.
