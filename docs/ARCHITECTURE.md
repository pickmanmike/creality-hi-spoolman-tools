# Architecture notes

## Two different data sets in Creality land

Creality’s ecosystem splits filament data into two “worlds”:

### A) Filament profile catalog (definitions)

This is what Filament-Sync maintains and uploads.

- `material_database.json`
- `material_option.json`

These define what a filament *profile* is:
vendor / type / name + the numeric “material id”.

### B) Slot/spool state (what’s loaded right now)

This is what the printer/CFS maintains.

- `material_box_info.json` (authoritative structured state)
- `tn_data.json` (includes raw RFID payload fragments)

This includes:

- which box + slot
- filamentId
- color
- remainLen (percent remaining)
- and (when RFID is present) decoded tag fields including `serialNum` (and legacy `reserve`)

## Why serialNum is used as the Spoolman identity bridge

Creality’s `serialNum` is a stable 6‑digit field.
Spoolman has a unique numeric `spool.id`.

So the clean bridge is:

- write `spool.id` into `serialNum`
- read it back from printer slot state
- update the matching spool in Spoolman

Legacy `reserve` remains parseable for older tags.

This repo implements the “read + sync” side.
