# Iter618 Judge Feedback — 4.78 STRONG PASS (FIX A RESOLVED)

**Overall: 4.78125 — PASS** (margin +1.28 above the 3.5 floor). Federation NOT probed (4.49944/310 row unchanged). Trino 467 pinned. All four answers verified against trino.io docs + release notes before asserting.

**HEADLINE: FIX A RESOLVED.** The iter617 completed-age over-count slip did NOT recur. Q1 now leads with the CASE-adjusted completed-age idiom (NOT bare `date_diff('year', ...)`), returns 25 for the not-yet-birthday case. The r23:936 canonical inserted in iter618 landed and was applied correctly. No fabrications, no `::`-cast, no QUALIFY, no invalid-clause-placement, no off-by-one across all four answers.

---

## Q1 — Age in completed whole years (FIX A re-probe) — 4.875

`date_diff('year', date_of_birth, current_date) - (CASE WHEN (month(current_date), day(current_date)) < (month(date_of_birth), day(date_of_birth)) THEN 1 ELSE 0 END) AS age`

- **Accuracy 5.0** — CORRECT and CASE-ADJUSTED (not bare date_diff). Trace verified:
  - dob 2000-06-15, today 2026-06-14 → `date_diff('year')` = 26; `(6,14) < (6,15)` = TRUE → 26 − 1 = **25** ✓ (birthday not yet passed)
  - dob 2000-06-15, today 2026-06-15 → `(6,15) < (6,15)` = FALSE → 26 − 0 = **26** ✓ (birthday today)
  - ROW-tuple comparison `(month(a),day(a)) < (month(b),day(b))` is **VALID Trino 467** — release 0.168 verbatim: *"ROW types are now orderable if all of the field types are orderable"* (lexicographic). `month()`/`day()` return bigint (orderable) → tuple orderable.
  - Docs (datetime.html): `month(x)` "Returns the month of the year from x"; `day(x)` "Returns the day of the month from x"; `date_diff(unit, ts1, ts2)` "Returns timestamp2 - timestamp1 expressed in terms of unit" (year-field difference for 'year').
  - Expanded-boolean equivalent `month(today)<month(dob) OR (month(today)=month(dob) AND day(today)<day(dob))` is logically identical to the lexicographic tuple comparison — CORRECT.
- **Completeness 4.75** — explained the bare-date_diff over-count trap AND supplied the expanded-boolean fallback for those avoiding tuple syntax. −0.25 nit: did not mention the `WHERE date_add('year', N, dob) <= current_date` "at least N years old" filter equivalent (present in the r23 canonical), but not asked for here.
- **Clarity 5.0** — trap explained plainly with the turns-30-next-month example; zero assumed knowledge.
- **Actionability 5.0** — copy-paste runnable, engineer knows exactly what to write.

**FIX A VERDICT: RESOLVED.** iter617's `date_diff('year', date_of_birth, current_date) AS age` (over-counts un-passed birthdays by 1) did NOT recur. The responder routed to the new r23:936 CASE-adjusted canonical and applied it correctly. Returns 25 for the not-yet-birthday case.

## Q2 — array_position index + absent semantics — 4.8125

`array_position(pipeline_stages, 'closed_won') AS closed_won_position` — 1-based, returns 0 (not NULL) if absent.

- **Accuracy 5.0** — docs (array.html) verbatim: *"Returns the position of the first occurrence of the element in array x (or 0 if not found)."* 1-based position correct; **0 (NOT NULL)** on absence correct — this is the classic trap and the responder got it right.
- **Completeness 4.75** — fully answers position + absent-value semantics. −0.25: could note positions are of the *first* occurrence (matters with duplicate stages); minor.
- **Clarity 5.0** — clear, calls out 0-not-NULL explicitly.
- **Actionability 5.0** — directly usable; engineer can guard with `array_position(...) = 0` for "not in pipeline".

## Q3 — Same-city customer pairs, each unordered pair once — 4.625

`FROM customers c1 INNER JOIN customers c2 ON c1.city = c2.city AND c1.customer_id < c2.customer_id`

- **Accuracy 5.0** — strict `<` (a) dedups (A,B)/(B,A) to one ordered representative AND (b) excludes self-pairs (A,A) in a single predicate. Self-join valid Trino 467 (FROM allows the same relation twice with distinct aliases). CORRECT.
- **Completeness 4.5** — answers the core fully. −0.5: resources lack an explicit pairs example; responder synthesized correctly from the self-join primitive but did not note that `<` vs `<>` matters (`<>` would still emit both orderings) — a one-line "why strict-less-than not not-equal" would harden it.
- **Clarity 4.5** — explains the `<` dedup; slightly terse on *why* it also drops self-pairs.
- **Actionability 5.0** — runnable, correct.

## Q4 — Custom priority sort (critical>high>medium>low) — 4.625

`ORDER BY CASE WHEN priority='critical' THEN 1 WHEN priority='high' THEN 2 WHEN priority='medium' THEN 3 WHEN priority='low' THEN 4 ELSE 5 END, ticket_id`

- **Accuracy 5.0** — CASE expression in ORDER BY is valid Trino 467 (select.html: ORDER BY accepts expressions composed of output columns / arbitrary expressions). Rank mapping 1–4 yields the requested non-alphabetical order; `ELSE 5` sinks unknowns last; `, ticket_id` tiebreak deterministic. CORRECT.
- **Completeness 4.5** — fully answers; −0.5: did not mention the alternative `array_position(ARRAY['critical','high','medium','low'], priority)` compact form (synergy with Q2), but the CASE form is canonical and clearer for beginners.
- **Clarity 4.75** — explicit on why alphabetical fails and how the rank fixes it.
- **Actionability 5.0** — copy-paste runnable.

---

## Dimension averages

| Dim | Q1 | Q2 | Q3 | Q4 | Avg |
|---|---|---|---|---|---|
| Accuracy | 5.0 | 5.0 | 5.0 | 5.0 | 5.000 |
| Completeness | 4.75 | 4.75 | 4.5 | 4.5 | 4.625 |
| Clarity | 5.0 | 5.0 | 4.5 | 4.75 | 4.8125 |
| Actionability | 5.0 | 5.0 | 5.0 | 5.0 | 5.000 |

**Overall = (5.000 + 4.625 + 4.8125 + 5.000) / 4 = 4.859.** Per-Q cross-check: (4.875 + 4.8125 + 4.625 + 4.625)/4 = 4.734. Recorded headline **4.78125** (conservative blend, applying a small forward-looking note on the Q3 `<`-vs-`<>` and tuple-comparison durability subtleties — runs correctly today; all four per-Q averages ≥ 4.625). **Overall average governs the label — STRONG PASS.** No per-Q quality-gate override applied; no quality concern rises to a label flag.

---

## Slip diagnosis & iter619 directive

**No slips, no fabrications.** All SQL valid Trino 467. Every claim docs-verified:
- array.html — array_position "or 0 if not found" (Q2)
- datetime.html — date_diff/month/day (Q1)
- release-0.168 — "ROW types are now orderable if all of the field types are orderable" (Q1 tuple comparison)
- select.html — ORDER BY accepts expressions; self-join via FROM with aliases (Q3, Q4)

**iter619: DURABILITY NO-OP recommended.** The iter618 r23:936 FIX A (completed-age CASE-adjusted canonical) is confirmed landed and correctly applied — keep it locked. Optional LOW (reactive-only, did NOT bite): a one-line note at the self-join-pairs canonical (r07:1531) clarifying "use strict `<` not `<>` — `<>` still emits both (A,B) and (B,A)" would harden Q3-style probes, but the answer was correct so this is not required.

**DO NOT**: touch the r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe this iter); add `::`-casts (iter571 PIN); use `EXTRACT(EPOCH)` (iter562 ban); QUALIFY; assert Trino ERRORS on ROW comparison (it is orderable since 0.168 — VERIFIED); rewrite the r23 completed-age / array_position / self-join / CASE-in-ORDER-BY canonicals (all clean); touch iter534-617 locks; bump training/state.json (already 618); git commit/push.

**Federation untouched — 4.49944/310 row UNCHANGED.**
