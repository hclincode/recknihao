# Training Loop Workflow

## Team

| Agent | Model | Role |
|---|---|---|
| `weak-ai-responder` | Haiku (small, limited context) | Production responder — answers only from `resources/` |
| `teacher` | Opus | Builds and improves `resources/` based on judge feedback |
| `judge` | Opus | Scores answers, maintains rubric, feeds back to teacher |
| `saas-engineer` | Sonnet | Generates realistic questions, reacts authentically |

## Loop (one iteration)

```
teacher
  └─ reads state.json + rubric.md + feedback-latest.md
  └─ writes/improves resources/
  └─ increments state.json iteration

saas-engineer
  └─ reads rubric.md (current focus topics)
  └─ generates 3–5 questions

  for each question:
    weak-ai-responder
      └─ reads resources/
      └─ answers question

    judge (early phase only — mid-cycle)
      └─ scores answer
      └─ updates rubric.md scores
      └─ writes feedback to feedback-latest.md

    saas-engineer
      └─ reacts: follow-up or confirm

judge (always — end of iteration)
  └─ writes end-of-iteration summary to feedback-latest.md
  └─ if final phase: decrements final_iterations_remaining in state.json
  └─ if all topics pass + final_iterations_remaining == 0: writes final-report.md, sets passed: true
```

## Phase transitions

**Early phase** (`state.json phase: "early"`):
- Judge gives feedback after every answer (mid-cycle).
- Continues until all required topics in `rubric.md` reach pass threshold (avg ≥ 3.5, ≥ 2 questions each).

**Transition to final phase**:
- Teacher sets `phase: "final"` and `final_iterations_remaining: 10` in `state.json`.
- Judge switches to end-of-iteration feedback only.
- Simulates production conditions where the teacher must make strategic decisions without real-time correction.

**Done**:
- All required topics pass AND `final_iterations_remaining` reaches 0.
- Judge writes `training/final-report.md` and sets `passed: true`.

## Starting a run

Invoke agents in this order:
1. `teacher` — "Start iteration, build resources for this session"
2. `saas-engineer` — "Generate questions for iteration N focusing on [topics]"
3. `weak-ai-responder` — "Answer: [question]"
4. `judge` — "Evaluate this answer: [question + answer]"
5. Repeat 3–4 for each question
6. `judge` — "Provide end-of-iteration summary"
7. Back to 1
