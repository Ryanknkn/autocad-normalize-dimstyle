---
name: autocad-normalize-dimstyle
description: Back up and normalize one AutoCAD DWG in a separate invisible AutoCAD instance. Use when the user asks to standardize dimension styles, consolidate dimensions into ISO-25, remove unused dimension styles, force a period decimal separator, move dimension annotations to the DIM layer, process dimensions inside layouts or block definitions, or fix inconsistent dimension text, arrows, scale, or ByLayer colors without interrupting the foreground AutoCAD session.
---

# AutoCAD Normalize Dimstyle

Normalize one closed `.dwg` file with the bundled deterministic scripts. Start a separate invisible AutoCAD instance; do not connect to the foreground AutoCAD instance.

## Required input

Obtain the exact path of one DWG. Confirm that the user authorizes modifying that file in place. The script always creates and verifies a timestamped backup before opening the target.

## Fixed standard

- Working style: `MHSA-DIM`
- Final local style: `ISO-25`
- Text height: `4`
- Arrow size: `2.5`
- Overall scale: `1`
- Dimension line color: ByLayer
- Extension line color: ByLayer
- Dimension text color: ByLayer
- Decimal separator: period (`.`)
- Dimension annotation layer: `DIM`; create it when absent
- Dimension text-style fixed height: `0`
- Scope: model space, layouts, and all non-Xref block definitions
- Xrefs: do not modify; report their names and dependent dimension styles

Preserve all unspecified settings from the target drawing's original `ISO-25`. Fail safely if the drawing has no local `ISO-25`.

## Run

Execute:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "<skill-dir>\scripts\normalize-dimstyle.ps1" -Path "<absolute-dwg-path>"
```

Use the absolute path to this skill directory. The script uses the installed `AutoCAD.Application.25` automation server in a separate invisible process.

## Safety rules

- Refuse to run when `.dwl`/`.dwl2` lock files exist or the DWG cannot be opened exclusively.
- Back up as `原文件名_修改前_yyyyMMdd_HHmmss.dwg`.
- Verify backup length and SHA-256 before modifying the original.
- Run a separate invisible AutoCAD 2025 instance, leaving foreground AutoCAD available for a different DWG.
- Never process a DWG that is open in the foreground.
- Never modify Xref files.
- Save first to a same-folder temporary DWG, reopen and verify it, and only then replace the original.
- Restore the original automatically from the verified backup if normalization, replacement, or post-save verification fails.
- Keep the backup after success.

## Workflow

The bundled AutoLISP performs this sequence:

1. Copy the drawing's original `ISO-25` into `MHSA-DIM`.
2. Apply the fixed standard to `MHSA-DIM`.
3. Create the local `DIM` layer when absent. Assign every internal dimension, legacy leader, and tolerance object to `MHSA-DIM` and move it to `DIM`; remove per-entity dimension-style overrides.
4. Verify the working style and all internal references.
5. Delete local dimension styles other than `ISO-25` and `MHSA-DIM`.
6. Copy `MHSA-DIM` settings into the original local `ISO-25`.
7. Assign all internal references to the real `ISO-25`; remove overrides again.
8. Delete `MHSA-DIM` and every other removable local dimension style.
9. Verify that internal references use `ISO-25`, are on `DIM`, use a period decimal separator, required parameters match, no overrides remain, and no other local dimension styles remain.
10. Save to a temporary DWG, reopen in the invisible AutoCAD instance, and verify again.
11. Replace the original only after the temporary DWG passes verification.

Xref-dependent styles may remain because their source files are intentionally untouched. Treat them as reported exceptions, not local failures.

## Report

Read the JSON emitted by the PowerShell script. Report:

- target and backup paths;
- processed dimension, leader, and tolerance counts;
- deleted style count;
- retained Xref names and Xref-dependent styles;
- final ISO-25 parameters;
- the decimal separator and dimension layer;
- success, restoration, or failure status.

Do not claim success unless the post-save verification status is `SUCCESS`.
