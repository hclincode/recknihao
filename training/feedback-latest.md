# Iteration 1250 — Judge Feedback

## Verdict

**Overall: 4.525 — STRONG PASS at iteration level, but Q3 individual FAIL flags a real CONTENT GAP that warrants a LIGHT FIX-A.** Per-Q scores: Q1=4.84, Q2=4.94, Q3=3.375 (FAIL), Q4=4.94. Average (4.84+4.94+3.375+4.94)/4 = 18.095/4 = **4.524**.

**iter1249 row-level-delete-reclaim WATCH CLOSES CLEANLY on first re-probe** — responder lifted the new r17 §185 LEADING CANONICAL verbatim: 2-step chain `EXECUTE optimize(file_size_threshold => '512MB')` THEN `EXECUTE expire_snapshots(retention_threshold => '7d')`, correctly flagged `remove_orphan_files` as failed-write debris only (NOT the lever for deleted-row reclaim), cited the new canonical's keyword anchors, AND correctly noted "raise file_size_threshold ABOVE delete-bearing file sizes to force the rewrite" — the load-bearing tuning detail r17 §195 explicitly teaches. Role-inversion fully corrected from iter1249's "expire is metadata-only" slip.

Q3 is the diametric opposite of the iter1249 dbt-snapshot recall-variance soft-watch — this time the responder reaches the right workaround and explains mechanics correctly, but **asserts a false negative** ("dbt has NO built-in 'skip already-succeeded models' flag") that contradicts the existence of the purpose-built `dbt retry` command (dbt-core 1.6+, references `target/run_results.json` to resume from point of failure). The companion selector `result:error+` is also missed. GREP confirms ZERO mentions of `dbt retry` in `resources/` and `result:error+` appears only as a bare list item at r27 §3858 — NOT as a canonical "re-run only what failed" pattern. **LIGHT FIX-A WARRANTED**.

---

## Per-question scoring

### Q1 — GDPR DELETE on day-partitioned table, deleted by user_id (NOT event_date); 3 weeks later MinIO storage unchanged; expire_snapshots reclaimed almost nothing — why, and Trino procedure sequence to reclaim disk?

**[RE-PROBE of iter1249 row-level-delete-reclaim WATCH]**

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.875 | All load-bearing facts CORRECT and match r17 §185 LEADING CANONICAL: (a) row-level DELETE on non-partition column writes position-delete files; data files stay FULL-SIZE and LIVE in the current snapshot — verified verbatim at r17 §189 + matches pinned `reference_trino_optimize_clears_position_deletes.md`; (b) `expire_snapshots` ALONE will NOT reclaim because the data files are still referenced by the current snapshot — correct (no role-inversion this iter); (c) Step 1 `EXECUTE optimize(file_size_threshold => '512MB')` applies+drops position-deletes per [trinodb/trino#12617](https://github.com/trinodb/trino/issues/12617) + [PR #23801](https://github.com/trinodb/trino/pull/23801) — verified; (d) Step 2 `EXECUTE expire_snapshots(retention_threshold => '7d')` drops now-unreferenced old files — verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) (WebFetched this iter) "removes all snapshots and all related metadata and data files"; (e) `remove_orphan_files` correctly framed as failed-write debris only, NOT the reclaim lever for logical deletes — matches r17 §183 + §205 DO-NOT-WRITE. Minor (-0.125): engineer's narrative said "ran CALL system.expire_snapshots" which is the Spark form; responder presented Trino EXECUTE form (implicit correction) but didn't explicitly call out "CALL is Spark; Trino is EXECUTE" — a beginner might miss the dialect distinction. |
| Beginner clarity | 4.75 | Numbered steps; explicit "why expire alone doesn't reclaim" mental model bridging the symptom-to-mechanism gap; "optional Step 3" framing prevents the engineer running `remove_orphan_files` thinking it's load-bearing. |
| Practical applicability | 5.0 | Copy-paste-ready 2-line chain with the load-bearing `file_size_threshold => '512MB'` tuning (the iter1249 r17 §195 detail teaching "raise above delete-bearing file sizes to force rewrite" reaches cleanly); engineer arrives at correct working sequence first try. |
| Completeness | 4.75 | All five sub-points covered (why-no-shrink, position-deletes mechanism, optimize lever, expire follow-on, remove_orphan_files defang). Minor compl shave for not flagging engineer's `CALL` → `EXECUTE` engine-dialect switch explicitly. |

**Average: (4.875 + 4.75 + 5.0 + 4.75) / 4 = 19.375/4 = 4.844 → STRONG PASS.**

**Watch closure**: `iter1249 row-level-delete-reclaim` **CLOSES CLEANLY on first re-probe** (25th consecutive 1st-re-probe-CLOSE in the LIGHT-FIX-A-then-CLOSE pattern). The new r17 §185 LEADING CANONICAL keyword anchors ("deleted rows but storage didn't shrink", "ran expire_snapshots but MinIO barely changed", "row-level delete reclaim storage", "what cleanup step after expire_snapshots") delivered findability — responder routed to the row-level canonical NOT the §159 partition-aligned one, and the file_size_threshold sizing detail propagated cleanly.

### Q2 — p50 + p95 response_ms per endpoint last 30 days, api_requests ~800M rows; Oracle PERCENTILE_CONT(0.95) WITHIN GROUP; Trino equivalent / approximate at scale?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All facts VERIFIED at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) (WebFetched this iter): (a) Trino 467 has NO `percentile_cont` / `percentile_disc` — confirmed absent from aggregate.html function list; (b) `approx_percentile(x, fraction)` and `approx_percentile(x, fractions ARRAY)` both verified — 4 overloads listed (single + array fraction, plus weighted variants); (c) ARRAY form returns array of same type, indexed `[1]`/`[2]` for percentiles[1]/percentiles[2] — correct 1-indexed; (d) T-Digest mental model + memory-bounded for 800M-row scale — correct; (e) **CRITICAL**: responder correctly noted NO published standard-error figure for `approx_percentile` — the 2.3% figure is for `approx_distinct` ONLY. Verified verbatim: `approx_distinct` docs say "should produce a standard error of 2.3%" while approx_percentile has no equivalent metric. Matches pinned `reference_trino_approx_percentile_error.md`. |
| Beginner clarity | 4.75 | Clear single-call vs array form contrast; explicit "T-Digest = memory-bounded approximation" mental model. |
| Practical applicability | 5.0 | Copy-paste-ready: single-call form for legibility OR array form for one-pass efficiency (relevant at 800M rows where a 2nd scan is meaningful cost). |
| Completeness | 5.0 | Both p50+p95 covered; both call shapes given; scale guidance + accuracy disclaimer all present. |

**Average: (5.0 + 4.75 + 5.0 + 5.0) / 4 = 19.75/4 = 4.9375 → STRONG PASS.**

### Q3 — dbt build re-ran ENTIRE 30-model DAG after fixing one downstream model that failed; want to re-run only the failed model + its downstream (not the 20-min upstream models that succeeded). Right retry flow?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.0 | Workaround `dbt build --select <fixed_model>+` IS correct mechanically (selector `model+` = model + descendants per [docs.getdbt.com/reference/node-selection/graph-operators](https://docs.getdbt.com/reference/node-selection/graph-operators)) AND `state:modified+` is a valid pattern when paired with `--state target/`. BUT the **canonical answer is missing** AND the claim "dbt has NO built-in 'skip already-succeeded models' flag; each dbt build is independent, doesn't query prior-run state" is **FACTUALLY WRONG**. **VERIFIED via WebFetch of [docs.getdbt.com/reference/commands/retry](https://docs.getdbt.com/reference/commands/retry)** this iter: `dbt retry` "re-executes the last invocation from the point of failure" and "references `run_results.json` to determine where to start" — that IS exactly the "skip-succeeded, re-run-failed-and-skipped-from-last-invocation" mechanism the responder claims doesn't exist. Available with `build`, `compile`, `clone`, `docs generate`, `seed`, `snapshot`, `test`, `run`, `run-operation`. Idempotent without code fixes. Available since dbt-core 1.6+. Additionally **VERIFIED at [docs.getdbt.com/reference/node-selection/methods](https://docs.getdbt.com/reference/node-selection/methods)**: `result:error` selects "resources that generated errors" from the prior run (requires `--state path/to/artifacts`); `result:error+` adds downstream descendants — selector-based equivalent of `dbt retry` for build/run commands. |
| Beginner clarity | 4.5 | Clear distinction between build vs run; correctly explains DAG-order interleaving and failed-upstream-skips-downstream cascade; numbered options. |
| Practical applicability | 3.5 | Workaround `--select <fixed_model>+` WILL work, BUT requires the engineer to manually identify the failed model name (which dbt retry would do automatically from `target/run_results.json`). For a 30-model DAG, this is friction. Also re-runs the failed model's full descendants even ones unchanged by the fix — exactly what retry's "resume from point of failure" semantics would scope better. Engineer arrives at a working answer but with the wrong mental model that dbt requires the manual workaround. |
| Completeness | 2.5 | Misses the canonical `dbt retry` command entirely. Misses `dbt build --select result:error+ --state target/` selector-based equivalent. Makes a false-negative claim ("dbt has NO built-in skip-succeeded flag") that future answers will perpetuate. |

**Average: (3.0 + 4.5 + 3.5 + 2.5) / 4 = 13.5/4 = 3.375 → FAIL.**

**Resource-source check (GREP)**:
- `dbt retry` — **ZERO mentions in `resources/`** — content gap.
- `result:error+` — appears ONCE at `resources/27-oracle-plsql-to-dbt-trino.md` §3858 as a bare list item alongside other selector methods, NOT as a canonical "re-run only what failed" pattern.
- `run_results.json` — 4 mentions in r28 (§1263, §1273, §1276, §1280) but only in the context of finding slowest models (`jq -r '.results[] | "\(.execution_time)\t\(.unique_id)"'`), NOT as the artifact that `dbt retry` / `result:error+` reads to scope the rerun.

**Verdict**: The responder's slip is **resource-sourced** — `dbt retry` simply isn't in the corpus, so the responder couldn't reach it. Selector `result:error+` is in the corpus but only as a list item without keyword-anchored "re-run only what failed" framing. The responder reached the workaround that IS in the corpus and over-confidently denied the existence of the canonical that ISN'T. **LIGHT FIX-A is warranted**.

### Q4 — Oracle `REGEXP_SUBSTR(url_path, '/accounts/([0-9]+)/', 1,1,NULL,1)` capture-group 1; Trino `regexp_extract` capture-group support?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Verified at [trino.io/docs/467/functions/regexp.html](https://trino.io/docs/467/functions/regexp.html) (WebFetched this iter): `regexp_extract(string, pattern, group) → varchar` — 3rd arg = capture group number, 1-indexed (docs example `regexp_extract('1a 2b 14m', '(\d+)([a-z]+)', 2) → 'a'` confirms 1-indexed); 2-arg form `regexp_extract(string, pattern)` returns "the first substring matched by the regular expression" (the whole match, NOT a specific capture group). Responder example `regexp_extract(url_path, '/accounts/([0-9]+)/', 1) → '12345'` matches docs verbatim semantics. Cross-engine note about `regexp_replace` using `$1` (Trino) vs `\1` (Oracle) is correct and useful. |
| Beginner clarity | 5.0 | Worked example; explicit no-3rd-arg-returns-whole-match disambiguation. |
| Practical applicability | 5.0 | Copy-paste-ready drop-in Oracle → Trino. |
| Completeness | 4.75 | Could mention the Oracle `REGEXP_SUBSTR(..., 1, 1, NULL, 1)` 6-arg form is (start_position=1, occurrence=1, match_param=NULL, subexpression=1) — Trino `regexp_extract` covers the subexpression slot (capture group) and implicitly handles start=1/occurrence=1; for non-1 occurrence Trino needs different mechanics. Minor recall ceiling, non-load-bearing for the asked URL-path use case. |

**Average: (5.0 + 5.0 + 5.0 + 4.75) / 4 = 19.75/4 = 4.9375 → STRONG PASS.**

---

## Watch status

| Watch | Open since | Status this iter | Reasoning |
|---|---|---|---|
| `iter1249 Q1 row-level-delete-reclaim`: EXECUTE optimize → expire_snapshots chain | iter1249 | **CLOSES CLEANLY** | Responder reached the new r17 §185 LEADING CANONICAL on first re-probe, with correct file_size_threshold tuning, correct optimize → expire_snapshots ordering, correct remove_orphan_files defang. 25th consecutive 1st-re-probe-CLOSE on the LIGHT-FIX-A-then-CLOSE pattern. |

### NEW open watch — Q3 dbt retry / result:error+ content gap

**Watch label**: `iter1250 Q3 dbt-retry-canonical-content-gap + result:error+-as-rerun-failed-selector`.

**Resource-source check confirms gap**:
- `dbt retry` — ZERO occurrences in `resources/`. Verified by GREP.
- `result:error+` — single bare-list occurrence at `resources/27-oracle-plsql-to-dbt-trino.md` §3858, no keyword anchoring around "re-run only failed", "skip already-succeeded", "selective rerun after failure".
- `run_results.json` — present in r28 but only in slowest-model-discovery context, not in retry-resume context.

The responder over-confidently denied the existence of the canonical mechanism. Findability + content gap (both halves).

**FIX-A recommendation (specific)**:

1. **r27 §6.7F (selector-section context) — ADD a card** titled *"LEADING CANONICAL — Re-run only what failed + downstream after a `dbt build` failure: `dbt retry` (canonical) or `dbt build --select result:error+ --state target/` (selector form)"*. Keyword anchors must include: "dbt build re-ran the entire DAG", "rerun only failed model and downstream", "skip already-succeeded models", "dbt retry from point of failure", "result:error+ selector", "20-minute upstream models succeeded don't re-run them", "select only the failed dbt model and its descendants", "what's the canonical dbt rerun-after-failure flow", "dbt run_results.json resume", "dbt retry idempotent".

   Card content must cover:
   - **Canonical**: `dbt retry` (dbt-core 1.6+) — re-executes the last invocation from the point of failure; reads `target/run_results.json` to identify failed + skipped nodes; idempotent without code fixes (same outcome if rerun on already-fixed state); works with `build`/`compile`/`clone`/`docs generate`/`seed`/`snapshot`/`test`/`run`/`run-operation`.
   - **Selector equivalent**: `dbt build --select result:error+ --state target/` — `result:error` selects nodes that errored in the prior run (read from `target/run_results.json`); `+` suffix adds downstream descendants; `--state target/` flag mandatory (points dbt at the artifacts).
   - **Difference**: `dbt retry` resumes from point of failure including downstream of FAILED + SKIPPED nodes; `result:error+` only re-runs nodes that ERRORED + their descendants (NOT nodes that were SKIPPED because an upstream failed — `result:skipped+` would do that). For the engineer's exact ask ("fixed one downstream model that failed, want to re-run only it + its downstream"), `dbt retry` is the closest fit.
   - **Workaround**: `dbt build --select <model_name>+` — works if engineer knows the failed model name manually (less convenient than retry, but useful when the fix changes the DAG selection scope rather than just being a bug-fix in the same model).
   - **DO-NOT-WRITE row**: *"dbt has no built-in flag to skip already-succeeded models — each `dbt build` is independent and doesn't read prior-run state."* — **FALSE.** `dbt retry` does exactly this; it reads `target/run_results.json`. The 30-model DAG re-running was because the engineer ran `dbt build` (full DAG) instead of `dbt retry`.
   - **Cross-link** to existing r27 §3858 mention of `result:error+` in the selector-methods list.

2. **r28 — ALSO surface** a one-line "see r27 §X for retry / result:error+ canonical" cross-link in §6.5 (dbt run is slow overall) where `run_results.json` is already discussed for slowest-model discovery. This pairs the two uses of `run_results.json` artifact (slowest-model tuning + retry-from-failure) at the same anchor.

**Verify points for the teacher when writing** (already verified this iter):
- `dbt retry` semantics — verified verbatim at [docs.getdbt.com/reference/commands/retry](https://docs.getdbt.com/reference/commands/retry): "Retry re-executes the last invocation from the point of failure" and "Retry references `run_results.json` to determine where to start" and "Executing retry without correcting the previous failures yields idempotent results."
- `dbt retry` available since dbt-core 1.6 (the examples shown use v1.6.1; introduced as part of the 1.6 cohort of commands per release notes).
- `result:error+` semantics — verified at [docs.getdbt.com/reference/node-selection/methods](https://docs.getdbt.com/reference/node-selection/methods): "The `result` method ... can be used to select resources based on their result status from a prior run. Note that one of the dbt commands [`run`, `test`, `build`, `seed`] must have been performed in order to create the result on which a result selector operates." `result:error` selects nodes that "generated errors"; `--state path/to/artifacts` required. `+` graph operator adds downstream per [docs.getdbt.com/reference/node-selection/graph-operators](https://docs.getdbt.com/reference/node-selection/graph-operators).

**Watch trigger**: re-probe `iter1250 Q3 dbt-retry-canonical-content-gap` in 4-8 iters under structurally-similar framings (e.g., "dbt run failed on 1 of 50 models, fixed it, don't want to wait another hour for the other 49", "dbt build is restarting from scratch every retry — what's the selective flow"). If responder still says "no built-in skip-succeeded flag" post-FIX-A, escalate to in-place reconciliation of the gap.

**No over-attractor risk** per `feedback_new_card_over_attracts_adjacent.md`: the new card is in a distinct conceptual neighborhood (operational rerun-after-failure) from adjacent dbt-cards (incremental materialization, snapshot SCD2, model versions, contracts) — different keyword surface, low cross-pollination risk.

---

## Other open watches (untouched this iter, status carried)

| Watch | Open since | Status |
|---|---|---|
| `iter1249 Q3 dbt-snapshot-recall-variance` | iter1249 | SOFT — untouched this iter (no dbt-snapshot probe). Stays open. |
| `iter1248 Q1 opener-coherence` | iter1248 | Untouched. |
| `iter1248 Q3 MATCH_RECOGNIZE-adjacency` | iter1248 | Untouched. |
| `iter1246 OOM-session-prop-direction` | iter1246 | Untouched. |
| `iter1241 concat-auto-coerces` | iter1241 | Untouched. |
| `iter1239 DF-wait-timeout` | iter1239 | Untouched. |
| `iter1238 broadcast-hedge` | iter1238 | Untouched. |
| `iter1236 rn=1-within-batch` | iter1236 | Untouched. |
| `iter1230 EXISTS-overwarning/::cast` | iter1230 | Untouched. |
| `iter1215 strpos-3-arg CEILING` | iter1215 | Untouched. |
| `iter1213 session_properties/(+)` | iter1213 | Untouched. |
| `iter1229 @v1-Spark` | iter1229 | Untouched. |

---

## Summary

- **Q1 STRONG PASS — iter1249 r17 ROW-LEVEL DELETE reclaim canonical reaches cleanly; watch CLOSES on first re-probe.**
- **Q2 STRONG PASS — Trino approx_percentile pin-perfect, including the no-published-standard-error-figure correctness.**
- **Q3 FAIL — content gap on `dbt retry` (zero corpus mentions) + `result:error+` (single bare-list mention); LIGHT FIX-A WARRANTED at r27 §6.7F.**
- **Q4 STRONG PASS — Trino regexp_extract 3-arg capture-group canonical clean.**

**Topics scored this iter** (per rubric assignment): Q1 → Iceberg table maintenance; Q2 → SQL query best practices for OLAP (approximate functions); Q3 → Improving complex SQL performance on Trino with dbt (dbt selective rerun is operational dbt-workflow, that row); Q4 → Oracle PL/SQL → dbt + Trino SQL migration (Oracle REGEXP_SUBSTR → Trino regexp_extract).
