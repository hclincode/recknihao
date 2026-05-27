# Score: Iter 344 Q1 — Iceberg table maintenance (compaction → expire → orphan ordering rationale)

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Core ordering rationale is correct and verified against Iceberg + Trino docs. The expire-before-orphan logic (both reasons) is textbook accurate. The 7-day default `older_than` claim is correct for the Trino Iceberg connector (default `retention_threshold = 7d`). One weak spot: the "Why compaction must come BEFORE expire_snapshots" explanation is slightly muddled — the real reason is operational efficiency (compaction creates orphans/old snapshots that expire then cleans up in the same maintenance window) rather than a true correctness/race risk. The wording "freshly-compacted files may not be protected by any surviving snapshot at the moment expiry ran, leaving them exposed" is misleading — `expire_snapshots` cannot delete files referenced by the current snapshot, regardless of when compaction runs. Iceberg's atomic commit semantics protect the new snapshot. This is a non-fatal but real overstatement of the failure mode. |
| Beginner clarity | 5.0 | Excellent. Opens by validating the engineer's copied order (reduces anxiety), names each procedure with its programmatic name plus a plain-English description, uses the "leases on files" analogy for snapshots, explicitly walks through what breaks in each swap direction, and ends with a memorable mnemonic. Zero unexplained jargon. The summary table at the end is a strong reinforcement. |
| Practical applicability | 5.0 | The engineer asked "what breaks if I flip the order" and got a direct, swap-by-swap answer they can put in their runbook. The closing line "Document the rationale in your runbook and don't change it without a specific reason" is exactly the right operational guidance. The in-flight write race scenario gives them a concrete failure mode to watch for. |
| Completeness | 4.5 | Addresses both ordering swaps the engineer asked about, plus the in-flight write protection angle, plus a fourth step (rewrite_manifests) for context. Minor gap: doesn't mention that the production stack (Trino 467 + Iceberg 1.5.2) ships with the 7-day minimum floor (`iceberg.remove-orphan-files.min-retention`) — would have been a nice production-environment hook. Also doesn't mention that compaction itself is sometimes run AFTER expire+orphan to compact the cleaner remaining state (a known alternative pattern). The answer presents one valid sequence as the canonical one without acknowledging legitimate variants. |
| **Average** | **4.75** | **STRONG PASS** |

## What Worked

- **Two-direction failure analysis**: For each ordering swap, the answer explains exactly what goes wrong. This is precisely what the question asked.
- **The "leases on files" mental model** for snapshots is excellent — it gives the engineer an intuitive way to reason about why orphan cleanup respects snapshots.
- **Two distinct reasons for expire-before-orphan** (exposing protected files + protecting in-flight writes) are both technically correct and were the iter344 pre-iter fix from resources/17. The fix is holding.
- **Concrete cost framing** ("an extra week of unnecessary storage cost") makes the abstract ordering rule actionable.
- **Quick mnemonic section** is exactly the kind of takeaway an oncall engineer wants to memorize.
- **Final "Document the rationale in your runbook"** is the right operational close.

## What Missed

- **Overstated compact-before-expire risk**: The claim that flipping compact and expire could leave "freshly-compacted files not protected by any surviving snapshot" is technically incorrect — Iceberg's atomic snapshot commits guarantee that whichever snapshot is current at commit time IS protected from expiry (expire_snapshots cannot delete files referenced by the current snapshot, by definition). The real reasons to compact first are: (1) operational efficiency — compaction creates old snapshots that the subsequent expire run will then clean up in the same window; (2) avoiding "wasted" expire work on files that compaction is about to obsolete anyway. The answer's framing makes it sound like a correctness/safety risk when it's really an efficiency/freshness optimization.
- **Production environment hook missed**: prod_info.md specifies Trino 467 + Iceberg 1.5.2 + on-prem MinIO. The answer mentions MinIO in the in-flight-writes example (good), but doesn't reference the 7-day Trino floor (`iceberg.remove-orphan-files.min-retention`) which would have grounded the recommendation in their specific stack.
- **No acknowledgment of alternative valid sequences**: Some practitioners run expire+orphan FIRST (to clean up first), then compact the cleaned state. The answer presents one ordering as the only safe one. Not wrong, but incomplete.
- **rewrite_manifests step is listed but not explained**: It appears in the numbered list and mnemonic but never gets its own "why" section. Minor.

## Technical Accuracy Verification

Verified against trino.io and iceberg.apache.org docs:

1. **Compaction creates a new snapshot before expire runs** — Confirmed. `rewrite_data_files` does write a new snapshot. However, the answer's specific risk framing (that the new files could be "exposed" if expire ran first) is overstated; Iceberg's atomic commits prevent this.
2. **expire_snapshots removes old snapshots and physically deletes unreferenced data files** — Confirmed. Per Iceberg docs: "removes old snapshots and data files which are uniquely required by those old snapshots."
3. **remove_orphan_files scans for files not in any snapshot — so expired snapshots expose more orphans** — Confirmed. Per Iceberg + IOMETE docs: "If you run orphan cleanup before expiring snapshots, files referenced by those snapshots are still considered live and will not be deleted."
4. **In-flight write race condition** — Confirmed. Per Iceberg docs: "dangerous to remove orphan files with a retention interval shorter than the time expected for any write to complete because it might corrupt the table if in-progress files are considered orphaned and are deleted." The answer's framing is accurate.
5. **7-day default** — Confirmed for Trino specifically. Trino's `retention_threshold` defaults to `7d` (different from Spark Iceberg's 3-day Java API default). The answer correctly uses 7 days because the prod stack is Trino-based. Good production-awareness.
6. **rewrite_manifests as "metadata index cleanup"** — Confirmed. It consolidates fragmented manifests for planning speed.

**Net verdict**: One real overstatement (compact-before-expire as a safety issue vs. efficiency issue), but every other technical claim verified. The answer is operationally safe — following its advice will not break a table. The pedagogy is excellent.

## Topic Update

- **Iceberg table maintenance**: 4.575/33 → **(4.575×33 + 4.75)/34 = 4.580/34 questions** — PASSED (recovering upward; ordering rationale gap from earlier iters now closed with both reasons surfaced. The resources/17 pre-iter fix is holding.)
