# Iter 366 Q1 Feedback — Cost considerations MinIO all-in $/TB-month 5th-angle direct probe

**Date**: 2026-05-30
**Phase**: extended
**Topic**: Cost considerations for analytical workloads at SaaS scale (5th angle — MinIO all-in $/TB-month direct probe per iter365 judge probe target #1, 4TH consecutive iter ask)

**Question**: "We keep telling our CFO that storage is basically free because the hardware is already paid for. But she's pushing back and saying we're not accounting for the full cost. What does MinIO storage actually cost per TB-month when you factor in everything — hardware refresh cycles, power and cooling, the extra storage overhead from whatever redundancy MinIO uses?"

**Score**: 4.00 — PASS (exactly at per-question 4.0 bar)

| Dimension | Score | Justification |
|---|---|---|
| Technical accuracy | 4.5 | EC 4+2 = 50% parity = 1.5x raw VERIFIED via MinIO docs. $20/TB-month sits inside the verified $10-22/TB-month industry band (Scality, OpenMetal). S3 $23.55/TB-month is correct ($0.023/GB × 1024). 80 TB → $19k/year math checks ($20 × 80 × 12 = $19,200). Minor: bundles ops/refresh together (verified data shows ops/FTE is the LARGEST single line at ~$200/TB over 5 years), doesn't ground rack/power/cooling 1.5-2x in PUE, doesn't distinguish capacity-HDD ($0.02-0.04/GB) from hot-NVMe ($0.10-0.20/GB) drive tiers. |
| Beginner clarity | 3.5 | 12TH ITERATION FLAGGED glossary backlog persists. "EC 4+2", "parity overhead", "amortized over 5 years", "raw storage per TB usable", "refresh cycle", "TCO" all used without inline definitions. A CFO reads the $20 bottom line fine but a SaaS engineer cannot defend "1.5x raw per TB usable" to follow-up questions. iter366 teacher action #1 (Quick Reference Key Terms table) per state.json claims to have landed but did not translate to the answer surface — either the table is too far down in resources/16 or the responder isn't pulling glossary content into answers. |
| Practical applicability | 4.0 | Strong on the single $20/TB-month CFO anchor + 80 TB worked example + S3 benchmark. Missing: (a) no "how to sanity-check your specific deployment" calculator pattern; (b) no callout that the CFO's "hardware paid for" intuition is ESPECIALLY wrong because hardware is only 15-25% of 5-year TCO per Scality/OpenMetal — this is the strongest single rebuttal and the answer leaves it on the table; (c) no admin/ops FTE as a SEPARATE line item (~$3.33/TB-month, ~17% of total). |
| Completeness | 4.0 | Covers hardware amortization, rack/power/cooling multiplier, EC overhead, refresh cycle, S3 benchmark, 80 TB worked example — six core components landed. Missing: admin FTE separately, PUE explicit (1.5-2.0x), network/backup separately, "hardware = 15-25% of TCO" CFO punchline, sensitivity bands ($15 low end / $25 high end). |

**Average**: (4.5 + 3.5 + 4.0 + 4.0) / 4 = **4.00 — PASS**

## What landed (iter366 teacher action validation)

iter366 teacher action #2 (MinIO all-in $15-25/TB-month with disks/EC/rack/power/cooling/refresh breakdown) LANDED cleanly. The 4-iteration backlog (flagged iter362, iter363, iter364, iter365) is CLOSED. The responder produced:
- All-in $20/TB-month anchor (inside verified $15-25 band)
- EC 4+2 = 50% parity overhead = 1.5x raw (mathematically correct per MinIO docs)
- Rack/power/cooling 1.5-2x multiplier on hardware (defensible industry heuristic)
- Disk $0.05-0.10/GB amortized 5 years (reasonable enterprise SSD/NVMe range)
- S3 Standard $23.55/TB-month under 50 TB benchmark (correct AWS pricing)
- 80 TB → $19k/year worked example (math verified)
- Explicit "hardware paid for is incomplete" CFO reframe

This validates the rubric-driven judge-probe-target → teacher-action → re-probe loop on the MinIO anchor specifically.

## What did NOT land (iter366 teacher action gap)

iter366 teacher action #1 (Quick Reference Key Terms table at top of resources/16) per state.json claims to have landed with DPU/DPU-hour/FTE/TCO/lift-and-shift/on-demand/Provisioned Capacity (7 terms). The Q1 probe was not the right test for the DPU/lift-and-shift terms (those would surface under an Athena/Glue probe), BUT the Q1 probe SHOULD have surfaced "TCO" and "FTE" if the table were being pulled into answers. Neither term appears in the answer. The 12th-iteration glossary backlog persists at the *answer surface* even though the *resource* may now have the table.

## Critical industry-data callout the responder missed

Per the verified Scality TCO data, **hardware acquisition is only 15-25% of 5-year TCO**. The other 75-85% (power, cooling, support, ops FTE, refresh) is RECURRING whether the hardware was bought today or 3 years ago. This is the single strongest rebuttal to the CFO's "hardware paid for" pushback and the responder buries it in the "incomplete" framing instead of leading with it.

## ITER367 TEACHER ACTIONS (priority order)

### MEDIUM priority

1. **Glossary landing at the answer surface (12TH-ITER ASK)** — The Quick Reference Key Terms table in resources/16 per iter366 teacher action #1 did not translate to Q1's answer surface. Two options: (a) move the glossary higher in the resource AND add an instruction "always cite from this table on cost answers"; (b) add specific inline definitions to the MinIO all-in subsection itself so the answer pulls them in directly:
   - "EC 4+2 = 4 data blocks + 2 parity blocks = 6 total. You can lose any 2 and still recover. 50% parity overhead = 1.5x raw storage per TB usable."
   - "Amortized = spreading one-time hardware cost across its 5-year useful life so monthly $/TB-month numbers reflect true ongoing cost not just first-month spike."
   - "Raw vs usable: raw = total disk bytes installed; usable = bytes available after EC overhead. For EC 4+2, 1 TB usable = 1.5 TB raw."
   - "PUE = power usage effectiveness = total facility power / IT equipment power. Typical data center 1.5-2.0; liquid-cooled <1.2."
   - "Refresh cycle = 5-year rolling disk replacement schedule. Drives wear out; budget ~20% of disk capex per year."
   - "TCO = total cost of ownership = all-in 5-year cost including hardware + power + cooling + support + ops FTE + refresh."

2. **"Hardware = 15-25% of TCO" CFO punchline** — Add as the LEADING reframe in the MinIO all-in section: "When your CFO says 'hardware is paid for', the rebuttal is: hardware acquisition is only 15-25% of 5-year TCO per industry data (Scality, OpenMetal). The other 75-85% — power, cooling, support, ops FTE, refresh — is recurring whether you bought the hardware today or 3 years ago." This is the single strongest rebuttal and the iter366 answer buried it.

3. **CFO calculator pattern** — Add a deployment-specific formula:
   ```
   $/TB-month = (disk $/GB × 1.5 EC multiplier × 1024 / 60 months)
              + (power kW × $0.12/kWh × 24 × 365 / 12 / TB-usable)
              + (ops FTE $200k / 60 TB-managed / 12)
   ```
   Engineer plugs in their numbers and produces a defensible per-deployment $/TB-month.

4. **Ops FTE/labor as a SEPARATE line item** — Currently bundled with "ops and disk refresh" in iter366 teacher action #2. Break out: "Ops FTE: 1 platform engineer ($200k loaded) per 200-500 TB managed = $3.33-8.33/TB-month. This is often the LARGEST single line item, larger than disk hardware itself."

### LOW priority

5. **Tiered drive cost breakdown** — Capacity HDD ($0.02-0.04/GB) vs hot NVMe ($0.10-0.20/GB). Current $0.05-0.10/GB range conflates the two tiers.

6. **PUE-grounded rack/power/cooling multiplier** — Replace "1.5-2x multiplier on hardware" with "PUE 1.5-2.0 for traditional cooling, <1.2 for liquid-cooled. Multiply raw power draw by PUE to get true facility power cost."

7. **Sensitivity bands** — "$15/TB-month low end (existing rack/power slack, capacity-tier disks, 1 FTE / 500+ TB), $20/TB-month typical, $25/TB-month high end (need to expand row, mixed NVMe/HDD, 1 FTE / 200 TB)". Single $20 number is defensible but ranged is more practical for CFO budgeting.

## ITER367 JUDGE PROBE TARGETS

1. **Cost considerations 6th angle** — glossary tier landing check via DPU/lift-and-shift probe (iter366 judge probe target #2 still untested; iter366 Q1 went to MinIO anchor instead).
2. **Query plan optimization 4th angle** — skew detection probe "GROUP BY by tenant_id is slow and EXPLAIN ANALYZE shows one Aggregation driver taking 10x longer than others" (iter366 judge probe target #3, iter366 teacher action #4 still untested).
3. **CDC tier 4th angle** — rotate to late-arriving updates MERGE INTO consistency OR snapshot isolation under concurrent writes.
4. **Trino federation 12TH-iter glossary landing check** — 12 consecutive iterations flagged, still untested at the answer surface.
5. **Cost considerations 7th angle** — ops FTE allocation probe at a different framing ("we're hiring our first dedicated platform engineer — how should we think about whether on-prem still makes sense at our size?") to test FTE-as-separate-line and crossover-heuristic durability.

## Sources verified via WebSearch (2026-05-30)

- [Erasure Coding — MinIO AIStor Documentation](https://min.io/docs/minio/linux/operations/concepts/erasure-coding.html) — EC 4+2 storage ratio = 6/4 = 1.5x raw, 50% parity overhead CONFIRMED
- [Configurable Data and Parity Drives on AIStor — MinIO Blog](https://blog.min.io/configurable-data-and-parity-drives-on-minio-server/) — EC parity tolerance and configurable ratios CONFIRMED
- [Storage Cost Per Terabyte Enterprise Calculation Guide — Scality](https://www.solved.scality.com/storage-cost-per-terabyte/) — hardware $200/TB + power $27/TB + cooling $15/TB + support $150/TB + ops $200/TB ≈ $592/TB over 5 years ≈ ~$10/TB-month low end; hardware is only 15-25% of 5-year TCO CONFIRMED
- [How to Calculate TCO for Hosted Private Clouds — OpenMetal](https://openmetal.io/resources/blog/how-to-calculate-total-cost-of-ownership-for-hosted-private-clouds/) — 1 PB 5-year TCO ≈ $1.31M ≈ ~$21.80/TB-month CONFIRMED
- [Data Center Power & Cooling Costs Enterprise TCO Guide 2026 — 3exhosting](https://www.3exhosting.com/data-center-power-and-cooling-costs-the-2026-enterprise-tco-guide/) — PUE 1.5-2.0 typical, liquid-cooled <1.2 CONFIRMED
- [AWS S3 Pricing](https://aws.amazon.com/s3/pricing/) — S3 Standard $0.023/GB-month × 1024 = $23.55/TB-month under 50 TB CONFIRMED

## Topic running average update

Cost considerations for analytical workloads at SaaS scale: 4.153/9 → **4.138/10 questions** — PASSED holds. Modest dip from BC glossary persistence, not substantive cost regression. Critical 4-iter MinIO-anchor backlog CLOSED. iter366 teacher action #2 LANDED.

---

## Iter 366 End-of-Iteration Summary

**Iteration average**: (4.00 + 3.625) / 2 = **3.8125 — FAIL** (below 4.0 per-iteration bar)

**Std-dev**: 0.1875 — tightened back down from earlier iterations but Q2 sank to the FAIL side.

### Per-question recap

| Q | Topic | Angle | Score | Verdict |
|---|---|---|---|---|
| Q1 | Cost considerations | 5th angle — MinIO all-in $/TB-month direct probe | 4.00 | PASS — 4-iter MinIO backlog CLOSED |
| Q2 | Query plan optimization | 4th angle — GROUP BY tenant_id skew detection | 3.625 | FAIL — bucket partitioning wrong remedy; missing salt/two-level GROUP BY |

### Q2 critical technical error (must-fix for iter367 teacher)

The responder recommended **bucket partitioning on tenant_id** as the remedy for whale-tenant GROUP BY skew. This is **WRONG for read-side aggregation skew**:
- Bucket partitioning distributes WRITE skew (where data lands across files), NOT READ-side aggregation skew at the Aggregation operator
- A whale tenant's GROUP BY rows still all hash to one driver regardless of how they were bucketed on write
- The canonical fix is **salting** (`GROUP BY tenant_id, hash(...) % N`) followed by a **two-level rollup** (final aggregate over the salted partial aggregates)
- Alternative remedies: `DISTRIBUTED_JOIN`/`task_concurrency` hints, `FORCE_SINGLE_NODE_OUTPUT=false`, partial+final aggregation isolation, or pre-aggregating whale tenants separately

This is a tier-1 technical accuracy error — recommending a fix that addresses a different problem class will actively mislead an engineer in production.

### What landed across iter366

1. **MinIO all-in $/TB-month** (iter366 teacher action #2) — LANDED at 4.00. 4-iteration backlog (iter362-365) CLOSED. EC 4+2 = 1.5x raw verified, $20/TB-month inside verified $15-25 band, S3 $23.55/TB-month benchmark correct, 80 TB → $19k/year worked example math clean. Single biggest iter366 win.

2. **Cost considerations topic durability** — 10 questions probed across 5 distinct angles (cloud-vs-on-prem, lift-and-shift, crossover heuristic, MinIO anchor). Topic running average 4.138/10 holds PASSED status comfortably.

### What did NOT land across iter366

1. **Glossary at the answer surface (12TH-iter ask)** — Quick Reference Key Terms tables added in iter366 teacher pass to resources/16, /18, /22 per state.json, but Q1's answer did not pull glossary terms (TCO, FTE, EC, amortized, PUE, raw-vs-usable). Resource-level landing without answer-surface landing. Either move glossary higher with explicit "always cite from this table" instruction OR inline definitions into the specific subsections being pulled.

2. **Query plan skew detection** (iter366 teacher action #4 + iter365 judge probe target #4) — FAILED at 3.625. Salting/two-level GROUP BY canonical fix MISSING. Bucket partitioning recommended incorrectly. EXPLAIN ANALYZE VERBOSE per-driver stats not mentioned. PartialAggregation/FinalAggregation split (iter365 medium #5) also missing despite teacher action commitment.

3. **"Hardware = 15-25% of TCO" CFO punchline** — Strongest single rebuttal to "hardware is paid for" intuition, buried in iter366 Q1 answer instead of led with.

### Topic running averages

- **Cost considerations for analytical workloads at SaaS scale**: 4.153/9 → **4.138/10** — PASSED holds.
- **Query plan optimization**: previous 2 durable angles (dynamic-filter, Exchange-operator) at 4.25 each → 3rd angle (skew detection) FAILS at 3.625 → topic still PASSED but trajectory weakened. Skew detection is now the **must-fix** for durable-3-angle status.

### Pattern observations

- **Iter360-366 iteration-average trajectory**: 4.0625 → 4.000 → 4.1875 → 4.0625 → 4.00 → 4.25 → **3.8125**. First sub-4.0 iteration in 3 iterations. The iter365 4.25 ceiling-break did not persist. Direct cause: Q2 substantive technical error on skew remedy, not BC/Comp ceiling drag.
- **Failure mode shift**: prior iterations failed on BC glossary drag with TA holding at 4.5. Iter366 Q2 failed on **TA itself** (wrong remedy class) — a more serious failure type because it indicates the resource lacks the canonical salting/two-level GROUP BY pattern, not just glossary polish.
- **Bimodal Q1/Q2 pattern returns** — iter365 std-dev 0.00 (both at 4.25) → iter366 std-dev 0.1875 (4.00/3.625). Q1 cost-considerations cleanly executed teacher action; Q2 query-plan-optimization teacher action either did not land in resources/18 or did not surface to the answer.

### ITER367 TEACHER ACTIONS — priority order

**HIGH**:
1. **Skew detection canonical fix MUST LAND in resources/18** — add explicit subsection on whale-tenant GROUP BY remedies:
   - **Salting pattern**: `SELECT tenant_id, SUM(metric) FROM (SELECT tenant_id, hash(rand()) % 32 AS salt, SUM(metric) AS metric FROM events GROUP BY tenant_id, salt) GROUP BY tenant_id` — two-level rollup distributes the whale tenant across 32 drivers in the partial aggregate, then re-aggregates.
   - **Why bucket partitioning is WRONG**: bucket partitioning distributes WRITE placement across files; the GROUP BY hash still sends all whale-tenant rows to one driver at the Aggregation stage. Make this explicit so the responder doesn't repeat the iter366 error.
   - **EXPLAIN ANALYZE VERBOSE per-driver stats** — `EXPLAIN ANALYZE VERBOSE SELECT ...` exposes per-driver input rows and CPU time. The skew signal is a single driver at 10x others in the Aggregation operator stats.
   - **Whale-tenant pre-aggregation pattern** — materialize whale-tenant rollups separately in a scheduled job, UNION ALL with on-the-fly small-tenant aggregates.
2. **Glossary answer-surface landing (12TH-iter ask)** — move Quick Reference Key Terms higher in resources/16, /18, /22 AND inline term definitions into the specific cost/plan subsections being pulled. Resource-level landing without answer-surface landing is incomplete.
3. **"Hardware = 15-25% of TCO" CFO punchline** as LEADING reframe in MinIO all-in subsection of resources/16.

**MEDIUM**:
4. **PartialAggregation/FinalAggregation explanation** in resources/18 (iter365 medium #5 still pending) — explains why Exchange row count < scan row count under healthy GROUP BY and surfaces high-cardinality footgun when they're approximately equal.
5. **LocalExchange vs RemoteExchange distinction** in resources/18 (iter365 medium #6 still pending).
6. **CFO calculator pattern** — deployment-specific $/TB-month formula for engineer to plug in own numbers.
7. **Ops FTE as SEPARATE line item** in resources/16 — currently bundled with refresh; break out as ~$3.33-8.33/TB-month often-largest-single-line.

**LOW**:
8. Tiered drive cost breakdown (HDD vs NVMe) in resources/16.
9. PUE-grounded rack/power/cooling multiplier in resources/16.
10. Sensitivity bands ($15/$20/$25 low/typical/high).

### ITER367 JUDGE PROBE TARGETS

1. **Query plan optimization 5th angle re-probe** — skew detection at a different framing ("our P99 dashboard query for one whale tenant is 20x slower than P50 across all tenants — how do we fix this in Trino?") to test whether iter367 teacher action #1 salting pattern landed. This is the must-clear target for durable-3-angle query-plan status.
2. **Cost considerations 6th angle** — glossary tier landing check via DPU/lift-and-shift probe (12TH-iter ask, iter366 judge probe target #2 still untested, iter366 Q1 went to MinIO instead).
3. **Trino federation 13TH-iter glossary landing check** — Build/Probe/BROADCAST/PARTITIONED/Dynamic filtering/Spill probe to test resources/22 glossary table landing at answer surface.
4. **CDC tier 4th angle** — late-arriving updates MERGE INTO consistency OR snapshot isolation under concurrent writes (still pending from iter365/366).
5. **Cost considerations 7th angle** — ops FTE crossover ("we're hiring our first dedicated platform engineer — how should we think about whether on-prem still makes sense at our size?") to test FTE-as-separate-line and crossover-heuristic durability.

### Verification status

- Q1 MinIO claims: VERIFIED via min.io/docs (EC 4+2 = 1.5x raw), solved.scality.com (15-25% TCO), openmetal.io (~$21.80/TB-month), 3exhosting.com (PUE 1.5-2.0), aws.amazon.com/s3/pricing ($23.55/TB-month). All cost claims independently verified.
- Q2 skew remedy: bucket partitioning recommendation FAILS verification against trino.io/docs/current/sql/select.html GROUP BY semantics — bucket placement affects write distribution, not read-side aggregation hash distribution. Canonical Trino skew pattern is salting (verified via trino.io/blog and trino-summit talks on data skew).
