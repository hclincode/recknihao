# Iter 687 — Judge Feedback

**Overall: 4.0625 PASS** (margin +0.5625 above 3.5 floor; -0.875 swing DOWN from iter686's 4.9375 STRONG PASS — Q4 storage-tiering LANDING-POINT MISS is the dominant delta; Q2 exposures contradictory-framing is a secondary clarity ding).

Per-Q (Acc / Comp / Clar / Act):
- **Q1 dbt model contract (two-layer enforcement)** — **5.00** (Acc5 / Comp5 / Clar5 / Act5)
- **Q2 dbt exposures / lineage** — **3.50** (Acc3 / Comp4 / Clar3 / Act4) [contradictory-framing flag]
- **Q3 dbt macro (cents-to-dollars DRY)** — **5.00** (Acc5 / Comp5 / Clar5 / Act5)
- **Q4 storage tiering (>90 day cold data on MinIO)** — **2.75** (Acc3 / Comp2 / Clar4 / Act2) [LANDING-POINT MISS flag]

Dim-avg cross-check: Acc(5+3+5+3)/4=4.00 / Comp(5+4+5+2)/4=4.00 / Clar(5+3+5+4)/4=4.25 / Act(5+4+5+2)/4=4.00 = (4.00+4.00+4.25+4.00)/4 = **4.0625** — agrees. GOVERNING LABEL = **PASS** (overall >= 3.5; per-Q quality-gate override NOT applied per directive; Q4 weakness flagged in prose only — Q4 2.75 is below 3.5 floor but per directive only OVERALL governs label).

---

## Q1 — dbt model contract / two-layer enforcement — 5.00 STRONG

Responder gave the canonical answer verbatim: `config.contract.enforced: true` on the `orders` model, `columns:` block with `name`/`data_type`/`constraints`, declared `order_id` as `not_null + primary_key`, `amount` as `decimal(18,2) not_null`. Crucially nailed the TWO-LAYER distinction:
- dbt-build-time enforces COLUMN NAMES + DATA TYPES at compile (build fails before SQL hits Trino)
- Trino/Iceberg enforces ONLY `not_null` at write time (Iceberg NOT NULL column DDL)
- `primary_key` / `unique` / `foreign_key` / `check` are METADATA ONLY — declared in YAML but NOT runtime-enforced
- Correct prescription: pair the contract with a dbt `unique` test (`data_tests: [unique, not_null]`) to catch dups post-materialize

VERIFIED against docs.getdbt.com/reference/resource-configs/trino-configs ("only constraints with type as not_null are supported") + docs.getdbt.com/reference/resource-properties/constraints + docs.getdbt.com/docs/collaborate/govern/model-contracts. Matches r27:2800-3023 §6.7C LEADING CANONICAL exactly. Zero defects.

## Q2 — dbt exposures / lineage — 3.50 CONTRADICTORY FRAMING FLAG

The exposures.yml CONFIG the responder delivered is CORRECT — `name: executive_dashboard`, `type: dashboard`, `owner` (name/email), `depends_on: [ref('orders'), ref('customers')]`, lives under `models/` (or any `*.yml`), and `dbt docs generate` + `dbt docs serve` renders the dashboard as a downstream node in the lineage DAG. Correctly noted exposures are documentation-only (no build-fail hook) and recommended pairing with contracts. All VERIFIED against docs.getdbt.com/docs/build/exposures (WebFetch 2026-06-08): exposures ARE the native first-class dbt feature for declaring external/downstream consumers; render with orange "EXP" indicator; do NOT fail build.

**BUT** the opening framing — "dbt doesn't yet have a native 'depends on external system' feature, so you have to work around it" — is FACTUALLY WRONG and directly contradicts the correct config that follows. Exposures ARE the native feature. The opening sentence creates user confusion: a reader who stops at the framing walks away thinking dbt lacks this capability; a reader who continues sees a correct exposures.yml but cannot reconcile it with the opening. -1.5 across Acc/Clar for the contradictory framing on a load-bearing fact.

## Q3 — dbt macro / DRY — 5.00 STRONG

Responder delivered the canonical Jinja-macro shape: `{% macro cents_to_dollars(cents_column) %} ROUND(CAST({{ cents_column }} AS DECIMAL(18,2)) / 100, 2) {% endmacro %}` in `macros/`, called at use-site as `{{ cents_to_dollars('total_cents') }}` across the 12 models. Correctly contrasted compile-time textual SQL substitution (macro) with materialized transformation layer (staging model + `ref()`), and prescribed when each is appropriate (macros for reusable expressions, staging models for transformation layers).

VERIFIED against docs.getdbt.com/docs/build/jinja-macros: `{% macro name(args) %} ... {% endmacro %}` defined in `macros/` dir, invoked via `{{ macro_name(args) }}`, performs compile-time textual SQL substitution (not runtime function call). Matches r27:3950-4080 §7A.3 + dbt_utils package mentions. Trino dialect note: `ROUND(CAST(x AS DECIMAL(18,2)) / 100, 2)` is valid Trino 467 (DECIMAL division produces DECIMAL, ROUND on DECIMAL valid). Zero defects.

## Q4 — storage tiering >90 day cold MinIO data — 2.75 LANDING-POINT MISS

**CRITICAL: the responder gave a "consult external docs / outside the scope of this resource set" non-answer despite the resources containing a fully-built canonical answer at r16:499-628.**

What the responder said:
- "I don't have enough information to answer this well"
- "the resources cover Iceberg maintenance (compaction, snapshot expiry) and storage sizing, but they don't document moving data between storage tiers"
- Hedged partial recipe: "check MinIO lifecycle support, partition old data + Spark job to move files, Iceberg doesn't have a built-in move-to-cold-tier operation, consult MinIO and Iceberg docs (outside the scope of this resource set)"
- Cited ONLY r17 (maintenance, which doesn't cover tiering)

What r16:499-628 actually contains (verified by reading the file):
- Full LEADING CANONICAL block titled "How do I tier hot vs cold storage on Trino + Iceberg + MinIO? Can I move old partitions to cheaper / archive storage?"
- Explicit statement: Trino 467 has NO `SET STORAGE TIER` clause, no `storage_tier`/`storage_class`/`tier` table property, no `iceberg.storage-tier.*` catalog property
- Three named mechanisms with engine/layer labels:
  - **Mechanism A — MinIO object-lifecycle tiering** (the canonical for this question): `mc ilm tier add <TIER_TYPE> <TARGET_ALIAS> <TIER_NAME>` registers remote tier; `mc ilm rule add --transition-days N --transition-tier <TIER_NAME>` attaches lifecycle rule. Scope rule prefix to `data/` (NOT `metadata/`, which must stay on hot tier for query-planning latency). Trino sees NO config change.
  - **Mechanism B — `compression_codec = 'ZSTD'`** table property (whole-table, not per-partition)
  - **Mechanism C — Application-layer recent-vs-archive split** (two Iceberg tables + UNION ALL view)
- Decision rule table mapping use cases to mechanisms
- Full DO-NOT-WRITE banned-forms table

**Directional instinct vs. concrete-recipe-delivery gap:** the responder's directional reasoning is roughly right (not Trino-native, MinIO-side, lifecycle + partition-by-date). What it failed to do is FIND the concrete recipe that exists, with named `mc ilm tier add` and `mc ilm rule add --transition-days N` subcommands and the critical `data/`-prefix-not-`metadata/` callout. Instead it told the user "outside the scope of this resource set, consult MinIO + Iceberg docs" — directly false; the recipe is in the resource set at r16:499.

**VERDICT: LANDING-POINT MISS.** The phrase "move cold data to cheaper storage automatically" / "configure in Trino, Iceberg, or elsewhere" steered the responder to r17 (maintenance) instead of r16 (cost-considerations -> tiering canonical). r17 has no tiering content AND has no cross-ref to r16:499; r16:499 has no inbound keyword anchors from "move cold data" / "automatically tier old data" / "archive cold data" / "hot-warm-cold" / "cold storage tier" beyond its own block-internal keyword list.

Penalties:
- Acc 3: directional facts right (Trino has no DDL; MinIO-side; partition by date) but missed concrete `mc ilm tier add` / `--transition-days` mechanism
- Comp 2: declared the answer ABSENT when it EXISTS; missed all three named mechanisms, decision rule, DO-NOT-WRITE banned forms
- Clar 4: the hedged answer itself is clearly written
- Act 2: "consult external docs" leaves the engineer no concrete next step despite a concrete recipe existing in the resource set

VERIFIED against trino.io/docs/467/connector/iceberg.html (no `SET STORAGE TIER`, no `storage_tier`/`storage_class`/`tier` table property, no `iceberg.storage-tier.*` catalog property family) + docs.min.io/enterprise/aistor-object-store/administration/object-lifecycle-management/ (mc ilm tier add + mc ilm rule add --transition-days N --transition-tier model) — r16:499 is docs-truth-correct.

---

## Storage tiering avg in rubric — re-estimate

Storage tiering row currently 4.25 over 2 datapoints. Adding Q4=2.75 gives running avg (4.25*2 + 2.75) / 3 = 11.25/3 = 3.75. Topic remains PASSED on overall threshold (3.75 >= 3.5), but margin is now THIN. Findability fix recommended.

---

## Teacher feedback — iter688 directive

**RECOMMENDED iter688 = FIX-A: storage-tiering FINDABILITY repair.** The r16:499 canonical content is docs-correct and complete. The defect is responder reachability — the "move cold data / archive old data / automatically tier" keyword surface does not route to r16:499.

Two surgical edits, no churn beyond:

### FIX-A.1 — Add inbound keyword anchors to r16:499 block

At r16:499 or in a new "Findability index" line immediately above the LEADING CANONICAL header, add a single sentence with the keyword surface that the question phrasing uses, e.g.:

> Keywords this block answers (for findability): **"move cold data to cheaper storage tier"**, **"automatically tier old data"**, **"archive cold data older than N days"**, **"move >90 day data to cheaper storage"**, **"hot / warm / cold storage tiering on MinIO"**, **"S3 Glacier equivalent on MinIO"**, **"lifecycle policy on Iceberg tables"**, **"per-partition storage class on Iceberg"**, **"how do I tier old partitions"**, **"automatic data archival on Iceberg + MinIO"**. (Existing block-internal keyword list at line 501 covers "tier / tiering / hot / cold / warm / archive / storage class / storage tier / lifecycle / move old partitions / cheaper storage / S3 Glacier equivalent" — extend to the longer-form phrasings above so keyword-matching responders trigger off natural-language SaaS-engineer phrasings, not just single-word tokens.)

### FIX-A.2 — Cross-ref from r17 maintenance -> r16:499 tiering

In r17 (iceberg-maintenance), add a one-line cross-ref at a high-findability location (top of file, or in a "Related topics" section if one exists), e.g.:

> **For storage-tiering questions** (moving cold data to cheaper storage, archiving old partitions, MinIO lifecycle policies, hot/warm/cold tier setup): see **r16 §LEADING CANONICAL — "How do I tier hot vs cold storage on Trino + Iceberg + MinIO?"** at r16:499. This maintenance resource does NOT cover tiering; tiering lives at the MinIO-ops layer (`mc ilm tier add` + `mc ilm rule add`), not the Iceberg-maintenance layer.

This cross-ref handles the failure mode observed in iter687: a responder lands on r17 (because the question uses the word "move", which keyword-matches maintenance operations like `optimize` / `expire_snapshots` / `orphan_files`), finds no tiering content, and concludes the resource set is silent. The cross-ref steers it to r16:499 instead.

### FIX-B (optional, low priority) — Q2 dbt exposures contradictory-framing inoculation

The exposures.yml config in the resources (mentioned in passing at r27:3004 as a use-case row in the When-to-use-contracts table; no dedicated leading-canonical block) is technically correct but understated. The responder filled the gap with a synthesized opening sentence that turned out to be wrong ("dbt doesn't yet have a native 'depends on external system' feature, so you have to work around it"). 

Optional inoculation: add a small leading-canonical block (or a single explicit sentence at r27:3004) stating "**dbt EXPOSURES are the native first-class dbt feature** for declaring external/downstream consumers (BI dashboards, ML applications, notebooks) in the dbt lineage DAG. Declared in `exposures:` YAML with `name` / `type` / `owner` / `depends_on: [ref('...')]`. Rendered into `dbt docs serve` as nodes with an orange 'EXP' marker. Documentation-only — do NOT fail dbt build." This is LOW PRIORITY because Q2 still passed (3.50 >= 3.5 floor) and the config the responder delivered was correct; only the framing was wrong.

### What NOT to do this iteration

- DO NOT bump `training/state.json` (teacher already set to 687)
- DO NOT touch r22 federation guardrails (43-iter ZERO probe streak; 4.49944 vs 4.5 thin)
- DO NOT touch r17 maintenance content; only ADD a one-line cross-ref to r16:499
- DO NOT rewrite the r16:499 canonical block (it is docs-truth-correct); only ADD inbound keyword anchors
- DO NOT touch r27 dbt-trino contracts content (iter687 Q1 confirmed durable; r27:2800-3023 §6.7C LEADING CANONICAL HELD)
- DO NOT add `::`-casts, QUALIFY, RLIKE, PERCENTILE_CONT/MEDIAN, EXTRACT(EPOCH), dayname/initcap, DISTINCT-ON, 0=Sunday Postgres carryover, `array_contains`, `array_slice`, `timestamp - timestamp`, `max_recursion_depth` defaults claims, CREATE TABLE PRIMARY/UNIQUE syntax, dbt snapshot `unique_key` against source-table columns, native Trino/Iceberg storage-tiering DDL fabrications, bare `MAX(col)` in WHERE, `CAST(naive_ts AS TIMESTAMP WITH TIME ZONE)` claiming to attach UTC

### Trajectory

iter660 -> 687: 5.00 -> 4.5625 -> 5.000 -> 3.656 -> 4.5625 -> 4.5625 -> 4.375 -> 4.125 -> 4.9375 -> 5.000 -> 4.9375 -> 5.000 -> 4.500 -> 4.875 -> 4.78 -> 4.5625 -> 4.875 -> 4.375 -> 5.000 -> 4.8125 -> 4.500 -> 4.9375 -> 4.3125 -> 4.9375 -> **4.0625**

Sustained 4.0+ across 30 of last 31 iterations; iter687 dip from iter686's 4.9375 driven entirely by Q4 LANDING-POINT MISS (Q1/Q3 both 5.00; Q2 3.50). Recovery path: FIX-A.1 + FIX-A.2 (storage-tiering findability) should restore Q4 to 4.5+ on next storage-tiering probe.

---

## Summary

**OVERALL: 4.0625 PASS** — two strong answers (Q1 dbt contracts two-layer 5.00 + Q3 dbt macro 5.00) + one contradictory-framing-but-correct-config (Q2 exposures 3.50, opening sentence claims dbt lacks a feature that IS the native first-class feature) + one LANDING-POINT MISS (Q4 storage tiering 2.75, "consult external docs" non-answer despite r16:499 canonical existing). **Q4 storage-tiering LANDING-POINT MISS verdict: r16:499 content exists and is docs-truth-correct, but responder routed to r17 instead of r16 from the "move cold data / automatically tier" phrasing.** **Q2 exposures contradictory-framing verdict: lower-priority — config delivered is correct, only the opening "dbt doesn't have a native feature" framing is wrong.** **iter688 recommended FIX-A: storage-tiering findability — add inbound keyword anchors to r16:499 + cross-ref from r17 -> r16:499 storage-tiering canonical.** **Optional iter688 FIX-B (low priority): exposures-as-native-feature explicit statement at r27:3004 or new small block.** Federation re-probe still untouched (43-iter ZERO probe streak; 4.49944 vs 4.5 thin margin).
