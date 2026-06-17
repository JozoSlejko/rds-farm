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

## markdownlint

CI runs markdownlint over `README.md` + `docs/**`. `MD013` (line length) is
**disabled**; all other defaults apply:

- One H1 per file; blank lines around headings, lists, and fenced code blocks.
- Every fenced code block declares a language (` ```bash `, ` ```powershell `,
  ` ```mermaid `, ` ```text `).
- File ends with a single trailing newline; no trailing spaces (markdown hard
  breaks excepted).
