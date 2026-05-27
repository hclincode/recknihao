# Iter 6 Q2 — Cost considerations for on-prem analytics stack

## Scores
- Technical accuracy: 4
- Beginner clarity: 4
- Practical applicability: 5
- Completeness: 4
- Average: 4.25

## Topic updated
- Topic name: "Cost considerations for analytical workloads at SaaS scale"
- Prior: 0 questions (no prior score)
- New avg: 4.25 (1 question)
- Status: needs 2nd angle before passing

## Key finding
The answer correctly structures cost around three layers (storage cheap, compute dominates, engineering FTE largest), maps them to the on-prem stack accurately, and gives a CTO-ready breakdown with a concrete scenario. The $18k hardware figure is synthesized and does not appear in resource 16, which explicitly frames on-prem storage as "already paid for" — this risks misleading a CTO who may not have a hardware purchase coming. The managed-cloud vs self-hosted crossover framing (which matters for a CTO making a "keep or replace" decision) is present in the resource but not surfaced in the answer.

## Resource gap
Resource 16 correctly positions engineering FTE as the dominant hidden cost, but does not give a "CTO-ready one-page summary" with a cost line-item table matching CFO/CTO expectations (hardware amortization, FTE salary allocation, k8s node budget as a cluster-sizing exercise). The $18k synthesized hardware figure suggests the responder is interpolating from missing content. Add a "one-year cost estimate template" section to `resources/16-cost-considerations.md` that explicitly separates: (1) hardware amortization (sunk cost if servers are already owned vs new purchase cost), (2) k8s node budget (vCPU/RAM cost if running in a co-lo or on leased hardware), (3) engineering FTE as a line item with guidance on how to estimate it honestly for a CTO who may push back, and (4) explicit instruction that storage is treated as a sunk cost on an already-provisioned MinIO cluster, not a new purchase unless adding disks.
