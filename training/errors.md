# Training Error Log

Entries written automatically when an agent fails and the loop auto-recovers. Use these to flag scores that need re-evaluation in the next teacher pass.

---

| Date | Iter | Q | Agent | Failure | Recovery |
|---|---|---|---|---|---|
| 2026-05-23 | 5 | Q4 | judge (Opus) | Socket timeout × 3 | Score written manually by orchestrator; conservative 3.25 avg — re-evaluate in iter 6 |
| 2026-05-23 | 5 | Q2 | judge (Opus) | Socket timeout × 1 | Retried — succeeded on 2nd attempt |
