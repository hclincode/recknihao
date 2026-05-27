# Iter 219 Q1 Judge Score

## Score: 3.05

## Topic: Trino federation cross-source connectors

## What the answer got right
- Correct `connector.name=mysql` and `jdbc:mysql://` JDBC URL prefix for the MySQL catalog.
- Correct that catalog file structure mirrors the Postgres one (different driver/URL but same shape).
- Correct that OSS Trino 467 MySQL connector has NO native connection pooling — same situation as Postgres; mitigation via JDBC URL params, server-side timeouts, and an external proxy (ProxySQL) is appropriate.
- Correct that cross-catalog joins do NOT push the join itself down — each side's predicates push down independently, then Trino executes the join on its workers.
- Correct framing of dynamic filtering (IN-list from build side to probe side at runtime) and how to spot it in `EXPLAIN ANALYZE` (`dynamicFilters = {...}` on probe-side scan).
- Correct EXPLAIN verification heuristic: `ScanFilterProject`/`Filter` above `TableScan` = predicate did NOT push down; `constraint` inside `TableScan` = pushed.
- Correct that storing all timestamps in UTC and explicitly verifying one row before shipping a cross-catalog timestamp join is a sound operational practice.
- Correct overall narrative that MySQL has a NARROWER set of pushdownable predicates than Postgres (just incorrectly described WHICH predicates).

## What the answer missed or got wrong
- **CRITICAL FACTUAL ERROR — LIKE pushdown for MySQL**: The answer claims `WHERE invoice_number LIKE 'INV-2026%'` pushes down on the MySQL connector. This is **WRONG**. Per the official Trino MySQL connector docs, "the connector does not support pushdown of any predicates on columns with textual types like CHAR or VARCHAR." Neither LIKE-prefix nor equality on string columns pushes down by default on MySQL. Only numeric/date/IN/IS NULL predicates on NON-textual columns push down. This is one of the most material differences between the MySQL and Postgres connectors — and the answer states the opposite.
- **CRITICAL FACTUAL ERROR — string equality on MySQL**: Implicit in the same MySQL doc statement: equality on VARCHAR (e.g. `WHERE status = 'paid'` if `status` is VARCHAR) does NOT push down on MySQL. The answer's own worked example in section 5 (`WHERE i.status = 'paid' ... pushes down to MySQL`) is likely WRONG if `status` is VARCHAR. This contradicts the docs and is exactly the gotcha the engineer asked about.
- **CRITICAL FACTUAL ERROR — `mysql.experimental.enable-string-pushdown-with-collate` is NOT a real config property**. The `experimental.enable-string-pushdown-with-collate` flag exists only for the PostgreSQL connector. There is no MySQL equivalent in Trino 467. Recommending a nonexistent config property is a serious failure — the engineer will paste it into `billing_mysql.properties`, the coordinator will fail to start (unknown property), and they'll waste time debugging.
- **Data type mapping error — MySQL TIMESTAMP vs DATETIME**: The answer claims "MySQL `DATETIME` and `TIMESTAMP`: Both map to Trino `TIMESTAMP`." This is wrong. Per the docs: MySQL `DATETIME(n)` → Trino `TIMESTAMP(n)`; MySQL `TIMESTAMP(n)` → Trino `TIMESTAMP(n) WITH TIME ZONE`. The connector actually DOES expose MySQL `TIMESTAMP` as timezone-aware in Trino, which inverts part of the answer's timezone-gotcha narrative. The real story is that MySQL `DATETIME` is the wall-clock type and the one to be careful about — but the answer conflates the two.
- **Missing — join pushdown for same-catalog joins**: The MySQL connector supports `join-pushdown.enabled=true` (AUTOMATIC by default) for joins between two tables in the SAME catalog. The answer's "no cross-catalog join pushdown" is correct but it never distinguishes that intra-catalog joins CAN push down. A worried engineer might infer that even a `billing_mysql.x JOIN billing_mysql.y` would not push down.
- **Missing — JVM/session timezone behavior**: The MySQL connector "sets the session time zone of the MySQL connection to match the JVM time zone." This is the actual mechanism behind the timezone gotcha — and it's the right operational lever to control (set the Trino coordinator/worker JVM timezone to UTC). The answer hand-waves at the symptom without naming this mechanism.
- **Missing — aggregate/limit/topN pushdown for MySQL**: The MySQL connector supports aggregate pushdown (count/sum/min/max/avg/stddev/variance), LIMIT pushdown, and TopN pushdown. None mentioned. Relevant context for "is MySQL basically the same as Postgres?"

## WebSearch verification notes
Verified against https://trino.io/docs/current/connector/mysql.html and https://trino.io/docs/current/connector/postgresql.html:
1. `connector.name=mysql` and `jdbc:mysql://` — confirmed correct.
2. MySQL connector "does not support pushdown of any predicates on columns with textual types like CHAR or VARCHAR" — answer's LIKE-prefix and string-equality pushdown claims are wrong.
3. `experimental.enable-string-pushdown-with-collate` is PostgreSQL-only — the answer's `mysql.experimental.enable-string-pushdown-with-collate` does not exist in OSS Trino.
4. Data type mapping: MySQL `DATETIME(n)` → Trino `TIMESTAMP(n)`; MySQL `TIMESTAMP(n)` → Trino `TIMESTAMP(n) WITH TIME ZONE`. Answer got this wrong.
5. MySQL connector DOES support same-catalog join pushdown (`join-pushdown.enabled=true`, AUTOMATIC). The "no cross-catalog join pushdown" claim is true but the same-catalog case was not distinguished.

## Recommendation for teacher
The resource `22-trino-federation-postgresql.md` is Postgres-focused; the responder appears to have generalized Postgres pushdown rules to MySQL by analogy. This is exactly the failure mode the engineer was worried about. Concrete fixes:

1. **Add a dedicated MySQL connector section (or a new resource `23-trino-federation-mysql.md`)** with a side-by-side MySQL-vs-Postgres pushdown table. Make the textual-column pushdown gap front-and-center:
   - Postgres: equality on VARCHAR pushes down; range on VARCHAR does NOT push down by default (gated by `postgresql.experimental.enable-string-pushdown-with-collate`).
   - MySQL: NO predicates on textual columns push down — period. LIKE-prefix does NOT push down. Equality on VARCHAR does NOT push down. There is NO `mysql.experimental.enable-string-pushdown-with-collate` flag.
   - Workaround for MySQL string pushdown: filter on a numeric/date column instead, or change the column type.

2. **Add a MySQL data type mapping table** that explicitly contrasts `DATETIME` (no TZ → Trino `TIMESTAMP`) vs `TIMESTAMP` (TZ → Trino `TIMESTAMP WITH TIME ZONE`). Call out the JVM-timezone session-mirroring behavior as the operational lever.

3. **Add a "what DOES push down on MySQL" list**: equality/IN/IS NULL on non-textual columns, aggregate pushdown, LIMIT/TopN pushdown, same-catalog JOIN pushdown (AUTOMATIC).

4. **Add a worked cross-catalog example** with a VARCHAR filter on the MySQL side to demonstrate that the predicate stays in Trino — the exact gotcha that bit this answer.

This is a high-impact resource gap. The current answer would actively mislead an engineer to (a) believe LIKE-prefix on MySQL pushes down, (b) paste a nonexistent config property into the catalog file, and (c) misunderstand which MySQL temporal type carries timezone semantics.
