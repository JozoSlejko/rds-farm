---
mode: 'agent'
description: 'Write or review a procedural guide (deploy/configure/migrate) to the rds-farm quality bar, then self-review.'
---

Write (or review) a procedural guide that a reader can follow knowing **nothing
beyond their goal**. Apply [`docs.instructions.md`](../instructions/docs.instructions.md)
and the bar below, then run the self-review and fix every miss before finishing.

## The bar

- **Audience + end state** in the opening line ("This takes you from X to Y").
- **Prerequisites are their own section** (a list) — each item says how to obtain
  or verify it. Never a callout, never folded into step 1.
- **One action per numbered step.** Split "configure" from "deploy".
- **Define every term on first use** (e.g. "staging" = the CA's rate-limit-free
  test environment that issues *untrusted* certs) or link a definition. No bare jargon.
- **who / what / where / how** per step — the exact tool, portal blade, file, or
  identity, not just the goal.
- **Connect outputs to consumers** — when a step produces a value, name the later
  step that uses it and how.
- **Explain every placeholder and flag** (`<sa>`, `-UseAppProxy`) inline or by link.
- **State the expected result / how to verify** each step worked.
- **No internal/dev vocabulary** ("Phase 1", bicep module names) in operator procedures.

## Self-review — run before finishing; fix every box you can't tick

Per numbered step:

- [ ] A first-time operator could do it with only what's on the page.
- [ ] Every term, flag, and placeholder is defined or linked.
- [ ] It is exactly one action.
- [ ] It states a verifiable result.

Per page:

- [ ] Audience + end state stated up top.
- [ ] Prerequisites in their own section, each with how-to-get/verify.
- [ ] Every produced value is connected to the step that consumes it.
- [ ] No internal phase/module vocabulary.
- [ ] markdownlint-clean.
