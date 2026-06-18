---
applyTo: '**/*.md'
description: 'Documentation style for the rds-farm docs.'
---

# Docs — rds-farm

- Every page under `docs/` opens with `[← Back to main README](../README.md)`.
- Use **GitHub alert callouts** (`> [!NOTE]`, `> [!IMPORTANT]`, `> [!WARNING]`),
  **mermaid** for diagrams, and tables for structured comparisons.
- Forward-looking design docs start with a **status callout** stating they're a
  blueprint and not yet implemented (see `docs/app-proxy.md`).
- Reference the real resource/parameter names from the repo; mark values that are
  lab-specific so readers don't copy them blindly.
- When you add a new `docs/` page, link it from the **documentation index table**
  in `README.md`.

## Writing a procedural guide (not just reference)

A *reference* documents what exists; a *guide* must be followable by someone who
knows **nothing beyond "I want to do this."** When a page tells the reader to **do**
something (deploy, configure, migrate), hold it to this bar. Apply the
[`write-guide`](../prompts/write-guide.prompt.md) checklist as you write and before
you finish (you can also invoke it directly with `/write-guide`); for a large new
page or a full-doc audit, delegate to the **RDS Docs** agent, which inherits this
same bar. The checklist:

- **State the audience + end state** in the opening line.
- **Prerequisites get their own section** (a list), each saying how to obtain or
  verify it — never buried in a callout or mixed into step 1.
- **One action per numbered step** — split "configure" from "deploy".
- **Define every term on first use** ("staging", "connector group",
  "split-horizon") or link a definition. No bare jargon.
- **who / what / where / how per step** — the exact tool, portal blade, file, or
  identity, not just the goal.
- **Connect outputs to consumers** — when a step produces a value, name the later
  step that uses it ("note the `<app>.msappproxy.net` value — you paste it in step 5").
- **Explain every placeholder and flag** in a command (`<sa>`, `-UseAppProxy`), or
  link where it's documented.
- **State the expected result / how to verify** each step worked.
- **No internal/dev vocabulary** ("Phase 1", bicep module names) in operator procedures.

## markdownlint

CI runs markdownlint over `README.md` + `docs/**`. `MD013` (line length) is
**disabled**; all other defaults apply:

- One H1 per file; blank lines around headings, lists, and fenced code blocks.
- Every fenced code block declares a language (` ```bash `, ` ```powershell `,
  ` ```mermaid `, ` ```text `).
- File ends with a single trailing newline; no trailing spaces (markdown hard
  breaks excepted).
