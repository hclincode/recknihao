# Iter 168 Q1 Judge Score — SSL/TLS for Postgres Catalog JDBC

**Question**: How do I enable SSL on a Trino PostgreSQL catalog's JDBC connection? Is it a flag, or do I need cert files?

**Production stack**: On-prem k8s, Trino 467, Iceberg 1.5.2, MinIO, HMS, JWT auth, OPA.

---

## Verification against authoritative sources

**WebSearch / WebFetch of trino.io/docs/current/connector/postgresql.html and jdbc.postgresql.org**:

1. **SSL in JDBC URL via `connection-url`** — CORRECT. Trino's PostgreSQL connector page explicitly documents: "enable TLS by appending the `ssl=true` parameter to the `connection-url` configuration property" with the example `jdbc:postgresql://example.net:5432/database?ssl=true`. The responder's general claim that SSL params live in the JDBC URL is correct.

2. **`sslmode=require` and `sslmode=verify-full`** — VALID pgjdbc modes. The pgjdbc docs list `disable`, `allow`, `prefer`, `require`, `verify-ca`, `verify-full`. The responder's characterizations are accurate: `require` encrypts but does not validate cert; `verify-full` validates cert and hostname.

3. **`sslrootcert`, `sslcert`, `sslkey`** — VALID pgjdbc parameters per the official pgjdbc SSL documentation page. Names and purposes are correct.

4. **Completeness of resources** — The responder honestly flagged that resources do not cover SSL specifics. However, **the official Trino 467 PostgreSQL connector documentation does cover the `ssl=true` flag explicitly** as the minimum configuration. The teacher's resources are missing it, but the responder also did not commit to even the documented baseline (`?ssl=true`) — it merely speculated.

5. **K8s cert mounting** — The suggestion to mount certs via k8s secrets and reference them by path in `connection-url` is the correct production approach (and fits the on-prem k8s production stack).

---

## Scoring

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4 | Everything stated is correct. The mechanism (URL query params), the parameter names (`ssl`, `sslmode`, `sslrootcert`, `sslcert`, `sslkey`), the difference between `require` and `verify-full`, and the k8s secrets approach are all accurate. Loses 1 point only because the responder hedged on `ssl=true` ("likely what you need") when Trino's own docs document it as THE example. |
| Beginner clarity | 4 | Plain language, no unexplained jargon, working catalog file example. The "What the resources do NOT document" framing is clear and helpful. Mildly weakened by the hedging tone — a beginner may be left unsure whether to actually try `ssl=true`. |
| Practical applicability | 3 | Engineer cannot copy-paste a complete working `connection-url` with SSL parameters. The directional pointer (jdbc.postgresql.org, sslmode options, mount certs via k8s secrets) is useful but the answer stops short of "here is the exact line to put in your `.properties` file". An engineer would have to do their own homework to actually finish the task. |
| Completeness | 3 | Addresses the core mechanism (URL query params) and names the right parameter families, but explicitly defers the most important production-grade specifics (verify-full + sslrootcert example, k8s secret mount manifest, the exact `connection-url` string). Misses that `ssl=true` is the documented Trino example and would have been a fully defensible answer. Does not address restart requirement, secret-file permissions (pgjdbc requires sslkey to be 0600 or PKCS-12), or how to verify the connection is actually encrypted (e.g., `pg_stat_ssl`). |

**Weighted = (4×2 + 4 + 3 + 3) / 5 = (8 + 4 + 3 + 3) / 5 = 18 / 5 = 3.60**

**Result**: 3.60 / 5 — PASS (just over 3.5 threshold) but well below the raised **4.5 threshold for Trino federation topic**.

---

## Critical findings for teacher

- **Resource gap**: The Trino federation resource (resources/22 or wherever Postgres catalog config lives) does NOT document SSL/TLS for the PostgreSQL connector, despite this being a question Trino's own docs cover directly. Add a section with:
  - The documented baseline: `?ssl=true`
  - The `sslmode` ladder: `disable` / `prefer` / `require` / `verify-ca` / `verify-full` and when to use which
  - Full production example with `sslmode=verify-full&sslrootcert=/etc/trino/certs/ca.crt`
  - K8s pattern: mount CA cert from Secret into Trino pod at `/etc/trino/certs/ca.crt`, reference by absolute path in `connection-url`
  - pgjdbc requirement that `sslkey` be PKCS-8 DER or PKCS-12, and file permissions
  - Verification: `SELECT * FROM pg_stat_ssl` on the Postgres side to confirm the Trino-originated session is encrypted
  - Note on restart: catalog property changes require Trino coordinator/worker restart (or catalog reload if dynamic catalogs enabled in 467)

- **Honest-admission behavior**: The responder's "I'd rather flag a gap than guess" instinct is a positive trait that should be preserved. The problem is not the honesty — it is that there was no need to flag a gap on the documented baseline (`ssl=true`). Resources need to cover this so future answers can be confident, not hedged.

---

## Sources

- [PostgreSQL connector — Trino docs (current)](https://trino.io/docs/current/connector/postgresql.html)
- [Using SSL — pgJDBC documentation](https://jdbc.postgresql.org/documentation/ssl/)
- [PostgreSQL libpq SSL Support (sslmode values)](https://www.postgresql.org/docs/current/libpq-ssl.html)
