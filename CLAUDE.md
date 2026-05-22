# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Agent team

Four agents collaborate in a training loop. See `training/workflow.md` for the full loop definition.

| Agent | Model | Purpose |
|---|---|---|
| `weak-ai-responder` | Haiku | Answers SaaS engineer questions using only `resources/` |
| `teacher` | Opus | Writes and improves `resources/` based on judge feedback |
| `judge` | Opus | Scores answers against the rubric, feeds back to teacher |
| `saas-engineer` | Sonnet | Asks realistic questions as a SaaS engineer with no OLAP background |

## Repo structure

- `resources/` — educational content the weak-ai-responder reads to answer questions
- `training/state.json` — current iteration, phase (`early`/`final`), and pass state
- `training/rubric.md` — required topic checklist and score history
- `training/workflow.md` — the iteration loop definition
- `training/feedback-latest.md` — judge's most recent feedback (written each iteration)

## Training loop phases

- **Early phase**: judge gives mid-cycle feedback after each answer. Teacher can adjust resources within the iteration.
- **Final phase**: last 10 iterations. Judge gives feedback only at end of iteration. Teacher must plan without real-time correction. Triggered when all required topics in the rubric reach the pass threshold.
