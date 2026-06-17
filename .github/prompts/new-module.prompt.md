---
mode: 'agent'
description: 'Scaffold a new Bicep module to repo conventions and wire it into main.bicep.'
---

Create a new Bicep module under `modules/` following this repo's conventions.

Ask me for the module's purpose and the resources it should create, then:

1. Create `modules/<name>.bicep`:
   - 2-space indent; `lowerCamelCase` params/vars with an `@description()` on each.
   - Secure-by-default (no `0.0.0.0/0`, no public exposure beyond the existing LB
     allow-list, private endpoints where applicable).
   - Expose the IDs/names the caller needs as `output`s.
2. Wire it into `main.bicep` (module reference + required params from existing
   params/outputs). Don't introduce new top-level params unless necessary.
3. If the module needs a **user-facing** value, add it to Tier 0
   (`scripts/Initialize-RdsFarm.ps1`) so it gets written into `main.bicepparam` —
   **do not** hand-edit the bicepparam.
4. Validate: `az bicep build main.bicep`. Resolve any analyzer warnings.

Follow `.github/instructions/bicep.instructions.md`. Don't commit unless I ask.
