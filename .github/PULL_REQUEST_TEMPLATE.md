<!-- Thanks for the PR! Keep the summary tight and tick the checklist. -->

## What & why

<!-- One or two sentences on the change and the problem it solves. -->

## Type of change

- [ ] `feat` — new capability
- [ ] `fix` — bug fix
- [ ] `docs` — documentation only
- [ ] `ci` / `chore` — tooling, workflows, config
- [ ] `refactor` — no behavior change

## Checklist

- [ ] Ran local validation (`az bicep build` + `build-params`, `tests/Test-*.ps1`,
      PSScriptAnalyzer) — or the `/validate` prompt — and it's green.
- [ ] **Did not** hand-edit `main.bicepparam` / `prereqs/tier0.bicepparam`
      (re-ran Tier 0 instead, if a value changed).
- [ ] `dsc/` files stay **ASCII** and Windows PowerShell **5.1-safe** (if touched).
- [ ] Docs updated and linked from the README index (if behavior/usage changed).
- [ ] No secrets, PFX/keys, or compiled ARM (`*.json`) committed.

## Deployment impact

<!-- Does this change Tier 0/1/2 behavior? Any what-if delta reviewers should expect? -->
