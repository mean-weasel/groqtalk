# Onboarding Microphone QA

## Objective

Fix and verify GroqTalk first-run onboarding so completing the wizard keeps the menu bar app alive, and microphone permission/setup behavior is covered by deterministic and opt-in live QA.

## Original Request

Use GoalBuddy goal-prep for `docs/superpowers/plans/2026-05-15-onboarding-microphone-qa.md`.

## Intake Summary

- Input shape: `existing_plan`
- Audience: GroqTalk maintainers and release QA.
- Authority: `requested`
- Proof type: `test`
- Completion proof: deterministic tests pass, live/opt-in microphone QA is documented and either passes or skips/fails with precise prerequisites, and manual/local evidence shows onboarding completion leaves GroqTalk running.
- Likely misfire: GoalBuddy could only add UI polish or documentation while missing the app-liveness regression, real microphone permission state flow, or CI safety constraints.
- Blind spots considered: macOS TCC prompts are not stable for regular CI; the currently dirty worktree contains live-debugging fixes that must be incorporated deliberately or separated before PR; onboarding and menu setup paths share related permission state but need separate coverage; temporary diagnostics should not become noisy production logs.
- Existing plan facts: Preserve `docs/superpowers/plans/2026-05-15-onboarding-microphone-qa.md`, including its file map, tasks, acceptance criteria, current evidence, and stop rule.

## Goal Kind

`existing_plan`

## Current Tranche

Validate the existing plan against the current dirty repo state, then complete successive safe verified slices until onboarding completion, deterministic microphone setup coverage, and opt-in live microphone QA are implemented and verified.

## Non-Negotiable Constraints

- Regular CI must not require real microphone hardware, macOS TCC prompts, Accessibility prompts, live Groq credentials, or manual intervention.
- Keep real microphone smoke tests opt-in.
- Preserve GroqTalk's menu bar app behavior: closing onboarding must not terminate the app.
- Do not silently remove or revert user/debugging changes; inspect current dirty files and work with them.
- Keep `/Applications/GroqTalk.app`/Developer ID launch behavior for manual permission QA if it remains necessary.
- Remove or narrow temporary noisy diagnostics before PR unless a debug-only diagnostic is explicitly useful.

## Stop Rule

Stop only when a final audit proves the full original outcome is complete: deterministic tests prove onboarding/microphone state behavior, local/manual evidence proves onboarding completion leaves GroqTalk running, and the opt-in live microphone target is documented and either passes on this machine or skips/fails with a precise prerequisite message.

Do not stop after planning, discovery, or one partial fix if safe Worker work remains.

## Slice Sizing

Safe means bounded, explicit, verified, and reversible. A good Worker task should complete a coherent behavior slice, not one tiny helper, unless a narrow failing test is the safest next move.

## Canonical Board

Machine truth lives at:

`docs/goals/onboarding-microphone-qa/state.yaml`

If this charter and `state.yaml` disagree, `state.yaml` wins for task status, active task, receipts, verification freshness, and completion truth.

## Run Command

```text
/goal Follow docs/goals/onboarding-microphone-qa/goal.md.
```

## PM Loop

On every `/goal` continuation:

1. Read this charter.
2. Read `state.yaml`.
3. Run the bundled GoalBuddy update checker when available and mention a newer version without blocking.
4. Re-check the intake, likely misfire, current dirty diff, and existing plan facts.
5. Work only on the active board task.
6. Assign Scout, Judge, Worker, or PM according to the task.
7. Write a compact receipt and update the board.
8. Continue to the next largest safe local work package unless blocked.
9. Finish only with a Judge or PM audit receipt that maps verification back to the original outcome and records `full_outcome_complete: true`.
