# Iter 519 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## Overall: 4.6875 STRONG PASS — BOTH iter518 fixes LANDED clean; one Q3 completeness gap surfaced

**Score**: (Q1 4.8125 + Q2 4.6875 + Q3 4.375 + Q4 4.875) / 4 = **18.75 / 4 = 4.6875 STRONG PASS** (+1.1875 above 3.5 floor; back to a healthy band after iter518's tighter +1.0469). **117th consecutive PASS in extended phase.** **NO NEW FABRICATIONS** this iter. Federation NOT probed — row stays **4.49944/310** unchanged (per iter472-519 directive).

---

## Iter518 fix landing — BOTH LANDED CLEAN

### FIX A (r17 strengthened LEADING CANONICAL) — Iceberg target-file-size flat-WITH `write_target_file_size_bytes` Q1 fab → **LANDED** (31st consecutive leading-canonical bulletproofing instance)
- Iter518 Q2 fab: responder invented `CREATE TABLE ... WITH (write_target_file_size_bytes = 268435456)` — a Trino DDL property that does NOT exist.
- Iter519 r17 strengthen-in-place at lines 727-771 added: (1) explicit DO-NOT-WRITE row banning the flat-underscore form, (2) explicit DO-NOT-WRITE row banning the `SET SESSION iceberg.write_target_file_size_bytes` session fab twin, (3) verbatim per-engine DDL block showing `extra_properties = map(ARRAY['write.target-file-size-bytes'], ARRAY['268435456'])` as the Trino route, (4) explicit Spark TBLPROPERTIES alternative, (5) Trino catalog `iceberg.target-max-file-size` + session `iceberg.target_max_file_size` underscore form.
- Iter519 Q1 response: **DID NOT** reproduce the flat-WITH fab. Correctly states "Trino 467 does NOT expose write.target-file-size-bytes as a WITH/SET PROPERTIES table property"; cites #28250; routes to `SET SESSION iceberg.target_max_file_size = 134217728` as the Trino knob; correctly frames "two separate knobs — session for Trino, table property for Spark"; advises setting both if both engines write. **The Q2 iter518 fab DID NOT REAPPEAR.**

### FIX B (r27 §4.5C NEW LEADING CANONICAL — ROWID dedup) — Iter518 Q3 messy mid-query alias mismatch + missing IN-PLACE forms → **LANDED**
- Iter518 Q3: responder gave a non-runnable inner query (`FIRST_VALUE(row_id) AS min_id` then outer `NOT IN` matched on undefined `id_within_group`); also did not address the IN-PLACE DELETE form the user asked about.
- Iter519 r27 §4.5C inserted at line 1354+ with: keyword anchors (9 phrases); "the one fact" Trino-has-no-ROWID; Pattern A READ-dedup `ROW_NUMBER()=1` subquery; Pattern B1 CTAS+DROP+RENAME; Pattern B2 MERGE+DELETE-on-rn>1; DO-NOT-WRITE table banning ROWID literal, `$row_id`, window-in-WHERE, QUALIFY, slow correlated EXISTS.
- Iter519 Q2 response: correctly states "Trino has NO ROWID (no _pos/_file either)"; READ-dedup uses ROW_NUMBER subquery (NO QUALIFY); REBUILD pattern B1 CTAS+DROP+RENAME; in-place pattern B2 MERGE matched-then-DELETE. **All three canonical patterns surfaced. No fake ROWID. No QUALIFY. No window-in-WHERE.**

---

## Per-question scoring

### Q1 — Iceberg target-file-size FROM Trino (no Spark) — 4.8125 STRONG PASS

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 4.75 | Correctly says Trino 467 does NOT expose `write.target-file-size-bytes` as a WITH/SET PROPERTIES allow-listed property; cites #28250; the Trino knob is the session `iceberg.target_max_file_size` / catalog `iceberg.target-max-file-size`; correctly frames Spark vs Trino as two knobs. **Minor accuracy gap (-0.25)**: omits that Trino CAN persist the dotted name via `extra_properties = map(...)` (Trino just doesn't honor it for Trino writes). Verified at [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) Configuration table: "`iceberg.target-max-file-size` — Target maximum size of written files; the actual size may be larger. — `1GB`". Also verified at [trinodb/trino #28250](https://github.com/trinodb/trino/issues/28250) — proposed-enhancement, pending. Session-property form `iceberg.target_max_file_size` confirmed as universal Trino hyphens-to-underscores convention. |
| Clarity | 5.0 | Clean Spark-vs-Trino split; "two knobs" framing; explicit byte values. |
| Applicability | 4.75 | Engineer ships a working SET SESSION call. Loses 0.25 for not surfacing the `extra_properties = map(...)` persistence path for shops who need the property recorded on the table itself for Spark downstream. |
| Completeness | 4.75 | Covers both engines, both forms, the gap; loses 0.25 for omitting `extra_properties` route. |

**Iter518 r17 flat-WITH fab DID NOT REAPPEAR** — 31st consecutive leading-canonical bulletproofing landing instance.

### Q2 — Oracle ROWID dedup DELETE → Trino — 4.6875 STRONG PASS

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 4.75 | "Trino has NO ROWID" correct (verified at [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) — SELECT grammar: "WITH ... SELECT ... FROM ... WHERE ... GROUP BY ... HAVING ... WINDOW ... ORDER BY ... OFFSET ... LIMIT" — no ROWID pseudocolumn, no QUALIFY). Pattern A ROW_NUMBER subquery valid Trino 467. Pattern B1 CTAS+DROP+RENAME valid (Iceberg metadata-only rename). Pattern B2 MERGE matched-then-DELETE valid. -0.25 for the B2 MERGE example using placeholder `<key_cols>` — the MERGE-dedup ON-clause is fiddly without a real unique tiebreak (B1 CTAS is the cleaner recommended path); responder should have flagged B1 as the safer default. |
| Clarity | 4.5 | Two-shape split (READ vs IN-PLACE) is clean; placeholder `<stable>` / `<key_cols>` slightly muddies the runnable-ness. |
| Applicability | 4.75 | Engineer ships Pattern A immediately; Pattern B1 is copy-pasteable. Pattern B2 needs the user to fill in placeholders. |
| Completeness | 4.5 | All three canonical patterns surfaced. Loses 0.5 for no explicit "B1 is cleaner / B2 needs a unique tiebreak" recommendation. |

**Iter519 r27 §4.5C canonical CONFIRMED LANDED** — 32nd consecutive leading-canonical bulletproofing landing instance. iter518 Q3 alias-mismatch confusion + missing IN-PLACE forms BOTH GONE.

### Q3 — dbt model auto GRANT SELECT on build — 4.375 PASS WITH COMPLETENESS GAP

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 4.5 | `post_hook` with `GRANT SELECT ON {{ this }} TO ROLE analyst_role` is a valid mechanism — runs after CTAS/MERGE commits, `{{ this }}` resolves to fully qualified name. OPA caveat is environment-correct (prod uses OPA for authz). -0.5 for OMITTING dbt's NATIVE canonical `grants` config — `{{ config(grants = {'select': ['analyst_role']}) }}` (Jinja) or YAML `config: grants: select: ['analyst_role']` (verified verbatim at [docs.getdbt.com/reference/resource-configs/grants](https://docs.getdbt.com/reference/resource-configs/grants): "When your model, seed, or snapshot finishes building, dbt ensures that the grants on its view or table match exactly the grants you have configured" — dbt applies grants idempotently). **Caveat — partial mitigation**: dbt-trino's grants config has a KNOWN BUG ([dbt-labs/dbt-core #12862](https://github.com/dbt-labs/dbt-core/issues/12862)) — it grants to USERS not ROLES — so for prod's Trino+ROLE case `post_hook` is actually MORE ROBUST than the canonical `grants:` config. Responder lucked into the right answer for the wrong reason. |
| Clarity | 4.5 | post_hook syntax + OPA caveat are clear. |
| Applicability | 4.25 | Engineer ships a working pattern. -0.75 for not mentioning the canonical `grants:` config exists (engineer who later reads the dbt docs will wonder why this codebase doesn't use it). |
| Completeness | 4.25 | Misses the native `grants:` config + the idempotency advantage of dbt's grants over post_hook (post_hook re-runs GRANT every build whether or not the grant is already there). |

### Q4 — LIKE vs REGEXP_LIKE — 4.875 STRONG PASS

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | LIKE (prefix-pushdown) vs REGEXP_LIKE (Java/JONI, contains-match) accurate. **Case-insensitive 3-arg fab pre-emption is the standout — verified at [trino.io/docs/current/functions/regexp.html](https://trino.io/docs/current/functions/regexp.html): only `regexp_like(string, pattern) → boolean` is documented; NO 3-arg flags form.** Responder correctly says "DO NOT use 3-arg `regexp_like(s, pattern, 'i')` (Oracle form, not supported in Trino), use `(?i)` inline" — matches Trino docs verbatim ((?i) is supported, (?d)/(?u) are not). `\1` vs `$1` capture-group distinction correct (Java replacement syntax, not POSIX). |
| Clarity | 5.0 | Clean when-to-switch rule; explicit migration warning. |
| Applicability | 4.75 | Engineer ships correct Trino regex; -0.25 for no explicit prefix-pushdown verification path (EXPLAIN look-up). |
| Completeness | 4.75 | Covers when-to-switch, performance, Oracle migration gotcha, JONI dialect. -0.25 for no explicit "non-prefix LIKE (`'%foo%'`) doesn't push down either" callout. |

---

## Topic average updates

- **SQL query best practices for OLAP** (Q2 ROWID dedup ROW_NUMBER + Q4 LIKE/REGEXP both map here): 4.5779/66 → (4.5779·66 + 4.6875 + 4.875)/68 = 311.7164/68 = **4.5840/68** (+0.0061 — both above topic avg).
- **Oracle PL/SQL → dbt + Trino SQL migration** (Q2 Oracle ROWID-DELETE port + Q3 dbt grants both map here): 4.5491/79 → (4.5491·79 + 4.6875 + 4.375)/81 = 368.4404/81 = **4.5487/81** (-0.0004 — Q3 slightly below topic avg drags but Q2 lifts).
- **Iceberg table maintenance** (Q1 target-file-size maps here): 4.4877/156 → (4.4877·156 + 4.8125)/157 = 704.8937/157 = **4.4898/157** (+0.0021 — Q1 above topic avg lifts).
- **Trino federation / cross-source connectors**: UNCHANGED at **4.49944/310** (federation NOT probed; per directive do NOT touch §13.x federation guardrails in resources/22 or the federation rubric row).

---

## Pattern observations

- **Bulletproofing streak holds — 31st + 32nd consecutive leading-canonical landing instances**: Both iter518 fixes (r17 strengthened target-file-size + r27 §4.5C new ROWID-dedup) landed clean on first re-probe.
- **No new fabrications this iter**: For the first time in 3 iters, no fab-class error introduced (iter516 was clean, iter517 had 2 fabs, iter518 had 1 fab, iter519 clean).
- **One real completeness gap**: Q3 dbt grants — responder used `post_hook` (which works) but omitted the native dbt `grants:` config (which is the canonical/preferred mechanism). The completeness gap is real but partially mitigated by the dbt-trino #12862 ROLE-vs-USER bug (post_hook is more robust for the Trino+ROLE case in prod's OPA setup).
- **Tightest margin band**: +1.1875 healthy after +1.0469 (iter518).

---

## NEW iter520 PRIMARY FIX TARGETS

### FIX C — dbt `grants:` config NEW CANONICAL (HIGH priority — completeness gap from iter519 Q3)

**WHERE**: r27 §6.x dbt-config cluster, new §6.7I (after iter517's §6.7H dbt-docs canonical). Likely placement: between §6.7H (dbt-docs) and the next existing sub-section.

**WHAT** (new canonical block):
- **The-one-fact**: "dbt has a NATIVE `grants` config that is the canonical/preferred mechanism — applies grants idempotently after each model run. `post_hook` with GRANT statements still works and is sometimes preferred for Trino+ROLE due to dbt-trino bug #12862."
- **Three forms**:
  1. Jinja in-model: `{{ config(grants = {'select': ['analyst_role']}) }}`
  2. YAML schema: `models: - name: my_model\n    config:\n      grants:\n        select: ['analyst_role']`
  3. Project-level default in `dbt_project.yml`: `models:\n  my_project:\n    +grants:\n      select: ['analyst_role']`
- **Precedence + merge behavior**: in-model > YAML > project-level; "merge and clobber" replaces less-specific with more-specific (per docs.getdbt.com/reference/resource-configs/grants verbatim "dbt's default behavior replaces the less-specific set of grantees with the more-specific set of grantees").
- **dbt-trino caveat (LOAD-BEARING for prod env)**: dbt-trino `grants` config has KNOWN BUG [dbt-labs/dbt-core #12862](https://github.com/dbt-labs/dbt-core/issues/12862) — emits `GRANT SELECT ON t TO analyst_role` (USER form) instead of `GRANT SELECT ON t TO ROLE analyst_role` (ROLE form). Workaround: use `post_hook` with explicit `GRANT SELECT ON {{ this }} TO ROLE <role>`. **Recommend `post_hook` for prod's Trino+OPA+ROLE setup until #12862 is fixed.**
- **Idempotency contrast**: dbt's `grants` config is idempotent (dbt shows existing grants, computes diff, only revokes/grants the difference); `post_hook` GRANT runs every build (Trino's GRANT is idempotent on the engine side so the net result matches, but emits more statements).
- **OPA caveat**: GRANT statements issue cleanly but OPA decides whether honored — prod uses OPA for authz, the dbt grants/post_hook is data-plane bookkeeping.
- **DO-NOT-WRITE bans**: "dbt-trino's grants config works perfectly for roles" (FALSE, bug #12862); "`post_hook` with GRANT is the only way to grant in dbt" (FALSE, native config is canonical for other adapters); "dbt's grants config emits ROLE not USER for Trino" (FALSE per #12862).
- **Verified sources**: docs.getdbt.com/reference/resource-configs/grants + docs.getdbt.com/blog/configuring-grants + dbt-labs/dbt-core #12862.
- **Keyword anchors**: "dbt grant select after model build / dbt model auto grant / dbt grants config / dbt post_hook GRANT / dbt-trino role grant bug / dbt analyst select access / dbt config grants select / dbt project-level grants / +grants dbt_project.yml / dbt idempotent grant".

### Iter520 probe targets

- **dbt grants RE-PROBE (HIGH)** — "Auto-grant SELECT to analyst_role after every dbt build — what's the canonical config?" verifies FIX C lands with native `grants:` config AS PRIMARY + `post_hook` workaround AS SECONDARY (due to #12862).
- **dbt-trino grants role-vs-user 2nd angle (HIGH)** — "My dbt grants config has `select: ['analyst_role']` but Trino isn't honoring it — analysts still get permission denied" verifies #12862 caveat surfaces + post_hook fallback recommendation.
- **Iceberg target-file-size extra_properties 3rd angle (MEDIUM)** — "How do I record `write.target-file-size-bytes` on the Iceberg table itself from Trino so Spark sees it later?" verifies the `extra_properties = map(...)` path (the only Q1 gap this iter).
- **ROWID dedup B1-vs-B2 recommendation 2nd angle (MEDIUM)** — "MERGE-dedup or CTAS-rebuild for dedup?" verifies §4.5C surfaces "B1 CTAS+RENAME is the cleaner recommended path; B2 MERGE needs a real unique tiebreak in the ON".
- **regexp_like flags 2nd angle (MEDIUM)** — "Can I do `regexp_like(name, '^abc', 'i')` for case-insensitive prefix?" verifies 3-arg fab does NOT slip back + `(?i)` inline canonical holds.
- **Federation stays UNPROBED (LOW)** — row stays 4.49944/310 per iter472-519 directive.

---

## Quoted verifications (load-bearing for this judgment)

- **Trino SELECT grammar — no QUALIFY** (verified [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html)): "SELECT [ ALL | DISTINCT ] select_expression [, ...] [ FROM from_item [, ...] ] [ WHERE condition ] [ GROUP BY ... ] [ HAVING condition] [ WINDOW window_definition_list] [ { UNION | INTERSECT | EXCEPT } ... ] [ ORDER BY ... ] [ OFFSET ... ] [ LIMIT ... ]" — NO QUALIFY clause; NO ROWID pseudocolumn.
- **Trino regexp_like signature — only 2-arg** (verified [trino.io/docs/current/functions/regexp.html](https://trino.io/docs/current/functions/regexp.html)): "`regexp_like(string, pattern) → boolean`". Only the (?i) inline flag is supported for case-insensitive matching; (?d) and (?u) not supported.
- **Trino Iceberg connector `iceberg.target-max-file-size`** (verified [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) Configuration): "Target maximum size of written files; the actual size may be larger." Default `1GB`. Session-property `iceberg.target_max_file_size` works via Trino's universal hyphens→underscores convention (operationally — official docs page does not list it in a dedicated session-properties table for this property, but it is supported per Trino's IcebergSessionProperties pattern).
- **Trino Iceberg `write.target-file-size-bytes` writer-side honoring**: per [trinodb/trino #28250](https://github.com/trinodb/trino/issues/28250) — "Proposed Enhancement: Support Iceberg table properties for write configuration (target-file-size-bytes and parquet.row-group-size-bytes)". Pending — Trino's own writer does NOT yet read the native dotted property even when persisted via `extra_properties`.
- **dbt grants config canonical** (verified [docs.getdbt.com/reference/resource-configs/grants](https://docs.getdbt.com/reference/resource-configs/grants)): "When your model, seed, or snapshot finishes building, dbt ensures that the grants on its view or table match exactly the grants you have configured" — applies grants idempotently. YAML form: `config: grants: select: ['analyst_role']`. Jinja form: `{{ config(grants = {'select': ['analyst_role']}) }}`. Project-level: `+grants: select: ['analyst_role']` in `dbt_project.yml`.
- **dbt-trino role-vs-user grants bug** (verified [dbt-labs/dbt-core #12862](https://github.com/dbt-labs/dbt-core/issues/12862)): grants config on dbt-trino emits USER grant not ROLE grant — open issue, post_hook with `GRANT ... TO ROLE` is the workaround. This is the load-bearing caveat for prod's Trino+OPA+ROLE environment.

---

**Iter519 summary**: Both iter518 fixes landed clean. No new fabrications. Q3 dbt-grants completeness gap surfaced — engineer ships working code via `post_hook` (which is actually MORE ROBUST for prod's Trino+ROLE due to dbt-trino #12862 bug), but the canonical `grants:` config is missing from resources. Iter520 PRIMARY FIX: add r27 §6.7I dbt-grants-config canonical with the #12862 caveat.
