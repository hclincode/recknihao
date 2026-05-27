# Score: iter265-q2

**Score**: 4.75 / 5.0
**Pass**: YES (pass threshold: 4.50)

## Dimension scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | All major claims verified against trino.io docs. One small imprecision: characterizing `flush_metadata_cache` as making "all Trino workers get the update" is misleading — JDBC connector metadata caching is a coordinator-side concern (the coordinator plans queries and resolves columns). The flush refreshes the coordinator's cache; worker phrasing risks confusing the engineer. Otherwise: `metadata.cache-ttl=0s` default is correct, the catalog-qualified `CALL app_pg.system.flush_metadata_cache()` syntax is valid per Trino's `CALL` docs (three-part fully-qualified naming), the view column-list freeze behavior is correct, and `CREATE OR REPLACE VIEW` is the right fix. |
| Beginner clarity | 5.0 | Jargon is minimal and always explained ("metadata cache", "expand SELECT *", "TTL" implicit but contextualized). Clear contrast between table-level fix and view-level fix. The "Tricky Part" framing draws the reader's attention to the non-obvious behavior. |
| Practical applicability | 5.0 | Step-by-step action checklist with exact SQL commands, exact config file path (`etc/catalog/app_pg.properties`), exact property name. Engineer can paste and run. Catalog name placeholder (`app_pg`) is realistic and called out as replaceable. Note: production environment in `prod_info.md` is on-prem Trino 467 + Iceberg + Postgres federation, and this advice fits cleanly. |
| Completeness | 4.5 | Covers both sub-parts of the question (cache refresh + view recreation) thoroughly. Includes verification steps after each fix. Minor gaps: (a) does not mention that the `flush_metadata_cache` procedure also accepts `schema_name`/`table_name` named parameters for targeted flushing — a useful option to mention; (b) does not mention that you can also restart Trino as a brute-force alternative (briefly alluded to once but not in checklist); (c) does not explicitly mention that on Trino 467 (production version), the procedure exists and works as described. None of these are critical omissions. |

**Average**: (4.5 + 5.0 + 5.0 + 4.5) / 4 = **4.75**

## What the answer got right
- Correctly states `metadata.cache-ttl` defaults to `0s` (caching disabled) — verified against trino.io PostgreSQL connector docs.
- Correctly identifies `CALL <catalog>.system.flush_metadata_cache()` as the refresh procedure. The fully-qualified catalog.system.procedure syntax is valid per Trino `CALL` docs.
- Correctly describes the key Trino view behavior: `SELECT *` is expanded to an explicit column list at CREATE time and frozen in the view definition. Adding columns to the underlying Postgres table does not change the stored view column list.
- Correctly recommends `CREATE OR REPLACE VIEW` as the safe fix and notes it is safe on a live view.
- Action checklist is concrete, ordered, and verifiable (DESCRIBE after each step).
- Covers both halves of the engineer's two-part question without padding.

## Gaps or errors
- "all Trino workers get the update" mischaracterizes how JDBC metadata caching works. Metadata caching for the PostgreSQL connector is on the coordinator (which does planning/metadata resolution), not on workers. The phrasing is not strictly wrong but is misleading and could plant a wrong mental model.
- Does not mention the named-parameter form `CALL system.flush_metadata_cache(schema_name => '...', table_name => '...')`, which lets the engineer flush only the affected table — useful when the catalog has many large schemas.
- Does not address the explicit-column-list view case until the very end, and does not explicitly say "if the view used SELECT col1, col2, you still need to add the new column manually — there is no automatic propagation either way." It does show this in the example but a one-line summary would have made it crisper.
- Does not note that on the production Trino version (467), this behavior is unchanged from current docs — a small fit-to-environment confirmation would have been a plus but is not required.

## Verified sources
- [PostgreSQL connector — Trino 481 Documentation](https://trino.io/docs/current/connector/postgresql.html) — confirmed `metadata.cache-ttl` default is `0s` (caching disabled) and `flush_metadata_cache` is the correct procedure.
- [CALL — Trino Documentation](https://trino.io/docs/current/sql/call.html) — confirmed fully-qualified `CALL catalog.schema.procedure()` is the standard syntax.
- [CREATE VIEW — Trino 481 Documentation](https://trino.io/docs/current/sql/create-view.html) — confirms view stores the query definition; combined with community references the SELECT * column-freeze behavior at CREATE time is the documented behavior.
