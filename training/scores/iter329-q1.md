# Iter 329 Q1 — OPA Bundle Management for Trino

**Topic**: Multi-tenant analytics (OPA bundle distribution)
**Current rubric avg before this score**: 4.477 across 124 questions

## Score table

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 5 | All key claims verified against OPA official docs |
| Beginner clarity | 4.5 | Strong jargon definitions; missed gloss on "Rego" itself |
| Practical applicability | 4.5 | Clear `curl` verification step; concrete directory layout; honest about config-detail gap |
| Completeness | 4.5 | Covers what/naming/serving; honest scope disclaimer on full config |
| **Average** | **4.625** | PASS |

## What worked

- **Naming rule called out as THE critical thing**: explicit "must be `data.json` or `data.yaml`; other filenames silently ignored" — this is exactly OPA's documented behavior and is the highest-leverage fact for the engineer's actual problem (managing growing tenant policies).
- **Directory-as-namespace explanation is concrete**: `bundle/tenants/data.json` → `data.tenants` is correct per OPA docs, and the responder showed both the file layout AND the Rego reference (`data.tenants.tenant_map[input.context.identity.user]`), so the engineer can verify end-to-end.
- **Verification step is excellent**: `curl http://opa:8181/v1/data/tenants` to check the data is actually loaded. This is the right diagnostic and follows directly from the directory-as-namespace rule.
- **No Trino-side decision cache** claim is correct and important — matches both the resource and trino.io OPA documentation (verified in iter317 and iter321 rubric history). This sets correct expectations about propagation timing.
- **Honest scope statement**: explicitly says "exact OPA configuration format ... are not documented in the available resources" and points the engineer to OPA docs. This is the right move — avoids fabrication, which has bitten this topic before (iter316 fabricated `opa.policy.cache-ttl-seconds`; iter322 fabrication noted in rubric).
- **Why-it-matters comparison** (individual files vs bundles) gives the engineer language to justify the migration to their team.
- **Propagation-window framing** at the end of the "serving" section is accurate and operationally useful (30s–5min poll cycle).

## What missed (minor gaps)

- **No mention of bundle compression format**: OPA bundles are conventionally `.tar.gz` archives. The responder describes the logical directory layout but doesn't mention the on-disk packaging the bundle server actually serves. An engineer building this for the first time may not know they need to `tar -czf bundle.tar.gz bundle/` before hosting.
- **No mention of `manifest.json` / `.manifest`**: bundles can include a root-level `.manifest` file declaring roots and revision metadata. Not strictly required but is standard practice for production bundles and worth a one-line callout.
- **"Bundle server" examples are vague**: S3, HTTP endpoint mentioned, but for the on-prem MinIO production environment (per `prod_info.md`), the most natural answer is "host the `.tar.gz` on MinIO via S3 protocol" or "serve from an internal nginx pod in the same k8s cluster." The responder didn't tailor to the on-prem k8s + MinIO stack.
- **No OPA config snippet at all**: even a minimal `services:` + `bundles:` YAML stub would have made the answer fully actionable. The responder appropriately deferred to OPA docs, but a single skeleton would have closed the gap without risk of fabrication.
- **"30 seconds to 5 minutes" poll interval** is a reasonable production range but is presented as "typical" without citing the `min_delay_seconds` / `max_delay_seconds` mechanism by name in the main flow (it's mentioned parenthetically). Could be tighter.

## Technical accuracy verification

Verified against the official OPA documentation (openpolicyagent.org/docs/management-bundles):

1. **`data.json` / `data.yaml` required filename** — **CORRECT**. OPA docs: "OPA will only load data files named `data.json` or `data.yaml`. Other JSON and YAML files will be ignored."
2. **Directory path becomes Rego data namespace** — **CORRECT**. OPA docs: "The hierarchical organization indicates to OPA where to load the data files into the `data` Document." Confirmed `bundle/tenants/data.json` → `data.tenants`.
3. **OPA polls bundles on regular interval** — **CORRECT**. OPA uses periodic short polling with `min_delay_seconds` / `max_delay_seconds` under `services.<name>` config; range is configurable.
4. **No decision cache on Trino's side** — **CORRECT**. Confirmed against trino.io OPA access control docs and prior rubric history (iter316/iter317/iter321 verified this). Trino OPA plugin has no decision TTL; the next query after bundle activation sees the new policy immediately.
5. **`curl http://opa:8181/v1/data/tenants` verification** — **CORRECT**. OPA's Data API exposes loaded data at `/v1/data/<path>`, and `8181` is OPA's default HTTP port.

No fabricated configuration properties, no fabricated log strings (a concern from earlier iterations on this topic — see iter322 rubric note about fabricated `ERRC: bundle download failed`). The responder cleanly avoided that trap.

## Rubric impact

Multi-tenant analytics topic moves from 4.477 / 124 to **(4.477 × 124 + 4.625) / 125 = 4.478 / 125 questions** — PASSED (stable).

This is a clean, well-bounded answer that fixes the historical naming-rule confusion (iter315 had `data/tenants.json` framing called out as wrong by the judge). The responder correctly inverted that to `tenants/data.json`, which is the directly testable fix the user needed.

## Sources

- [Bundles | Open Policy Agent](https://www.openpolicyagent.org/docs/management-bundles)
- [Open Policy Agent access control — Trino 481 Documentation](https://trino.io/docs/current/security/opa-access-control.html)
