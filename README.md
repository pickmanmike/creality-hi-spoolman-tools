# Creality Hi / CFS ↔ Spoolman Tools

PowerShell tools that connect the dots between:

- **Creality Hi + CFS slot state** (what’s physically loaded *right now*)  
- **Spoolman** (your filament / spool inventory database)  
- **Filament-Sync** (your *filament profile catalog* for Creality printers)  
- **RFID for CFS (Windows)** (programs Creality RFID tags + optionally creates spools in Spoolman)

This repo focuses on the **Spoolman side** of the ecosystem: importing Creality profiles into Spoolman, and keeping **Spoolman spool locations / remaining weight** in sync with the printer’s CFS.

---

## The “contract” that makes it all work

To identify a *physical spool* across swaps/moves, we need a spool-level ID. Creality’s tag format includes a 6‑character **`reserve`** field.

**We use:**

> `RFID reserve (6 chars)  ==  Spoolman spool.id` (zero‑padded)

Example:

- Spoolman `spool.id` = `123`
- RFID `reserve` = `"000123"`

That gives a stable 1:1 mapping: slot → reserve → Spoolman spool record.

> If you prefer hex (6 chars), this repo supports it too (`reserveMode: "hex"`).

---

## What’s in this repo

### Tools

| Script | Purpose |
|---|---|
| `tools/setup-spoolman-and-sync.ps1` | Helper to install/run Spoolman via Docker Compose **and** wire in the Creality→Spoolman profile sync |
| `tools/sync-creality-materials-to-spoolman-masters.ps1` | Imports Creality filament profiles as **MASTER** (vendor + filament templates, no per-color variants) |
| `tools/sync-creality-materials-to-spoolman.ps1` | Imports Creality filament profiles as regular filaments (older / alternate strategy) |
| `tools/sync-cfs-slots-to-spoolman.ps1` | Reads `material_box_info.json` from printer(s) over SSH and PATCHes Spoolman spool locations (and optionally remaining weight) |
| `tools/run-cfs-slot-sync.ps1` | Wrapper for Task Scheduler: logging + overlap protection |

### Config / examples

- `config/cfs-spoolman-bridge.example.json` – copy to `config/cfs-spoolman-bridge.json` and edit  
- `examples/docker-compose.spoolman.yml` – a starter Spoolman compose file (host port `7912` → container port `8000`)

### Optional patch

- `patches/k2-rfid-spoolman-reserve-v2-git.patch` – patch for the Windows RFID tool to write the Spoolman `spool.id` into the tag’s `reserve` field.

---

## How it fits into the “Filament Ecosystem”

```mermaid
flowchart LR
  subgraph Slicer PC["Windows 'Printer PC'"]
    FS["Filament-Sync<br/>profile catalog → printer DB"]
    SM["Spoolman<br/>inventory + spools"]
    Tools["This repo<br/>Spoolman tools"]
    RFID["RFID for CFS (Windows)<br/>writes tags + (optionally) creates spools"]
  end

  subgraph Printer["Creality Hi / CFS"]
    Box["material_box_info.json<br/>(slot state, reserve, remainLen)"]
    CFS["CFS hardware<br/>reads RFID tags"]
  end

  FS -->|uploads profiles| Printer
  CFS --> Box
  Tools -->|SSH read-only| Box
  Tools -->|PATCH /api/v1/spool/{id}| SM
  RFID -->|create spool + write reserve=spool.id| SM
  RFID -->|write tag| CFS
```

---

## Prerequisites

### Required

- Windows 10/11 (or any OS with PowerShell + SSH, but this repo is optimized for Windows)
- **PowerShell 7** (`pwsh`) recommended (some scripts run in 5.1, but the setup tool assumes 7+)
- **Docker** (Docker Desktop on Windows) if you want to run Spoolman locally via containers
- **OpenSSH client** on the machine running the scripts (`ssh` must be available in PATH)

### Optional (but useful)

- PowerShell module `Posh-SSH` if you want password-based SSH without interactive prompts (scheduled tasks can’t answer prompts)

---

## Setup (end-to-end)

### 1) Install / run Spoolman (Docker Compose)

1. Create a folder (example): `C:\Users\<you>\spoolman`
2. Create `docker-compose.yml` in that folder (or copy `examples/docker-compose.spoolman.yml`)
3. Create a `data` subfolder next to the compose file
4. Run:

```powershell
cd $env:USERPROFILE\spoolman
docker compose up -d
```

Open Spoolman:

- `http://localhost:7912`

> If you already run Spoolman elsewhere, that’s fine — just point the config at it.

---

### 2) Import Creality profiles into Spoolman (MASTER templates)

You need a Creality-style `material_database.json` locally.

Typical sources:

- Filament-Sync output file (recommended), or
- SCP it from the printer (advanced)

Run:

```powershell
pwsh ./tools/sync-creality-materials-to-spoolman-masters.ps1 `
  -MaterialDatabasePath "C:\path\to\material_database.json" `
  -SpoolmanUrl "http://127.0.0.1:7912"
```

If you want it to update existing MASTER filaments:

```powershell
pwsh ./tools/sync-creality-materials-to-spoolman-masters.ps1 `
  -MaterialDatabasePath "C:\path\to\material_database.json" `
  -SpoolmanUrl "http://127.0.0.1:7912" `
  -UpdateExistingFilaments
```

---

### 3) Program RFID tags and create Spoolman spools

You have two common approaches:

- **Use our patched fork of the RFID tool** (recommended): it can create a Spoolman spool and then write `reserve = spool.id`.
- **Manual:** create the spool in Spoolman, then write the reserve field yourself (error-prone, but possible).

Either way, the goal is always:

> the tag reserve field contains the Spoolman spool.id (6 chars)

---

### 4) Configure the CFS→Spoolman bridge

1. Copy the example config:

```powershell
Copy-Item ./config/cfs-spoolman-bridge.example.json ./config/cfs-spoolman-bridge.json
```

2. Edit `./config/cfs-spoolman-bridge.json`:

- Set `spoolmanUrl`
- Add your printer(s) under `printers`
- Prefer `sshAuth: "key"` and set `sshKeyPath`

---

### 5) Run the CFS slot sync

Dry-run first (prints what it *would* do):

```powershell
pwsh ./tools/sync-cfs-slots-to-spoolman.ps1 -ConfigPath ./config/cfs-spoolman-bridge.json -DryRun -VerboseSlots
```

Real run:

```powershell
pwsh ./tools/sync-cfs-slots-to-spoolman.ps1 -ConfigPath ./config/cfs-spoolman-bridge.json -ContinueOnPrinterError
```

Optional flags:

- `-UpdateRemainingWeight` (or set `"updateRemainingWeight": true` in config)
- `-ClearMissing` (clears Spoolman locations for spools that were previously seen but are no longer loaded)

> Safety: if any printer fails in a run, `-ClearMissing` is automatically skipped.

---

### 6) Schedule it (Windows Task Scheduler)

You can schedule either:

- `tools/sync-cfs-slots-to-spoolman.ps1` directly, or
- the wrapper `tools/run-cfs-slot-sync.ps1` (recommended: logs + overlap protection)

Example Task Scheduler action:

```text
Program/script:  pwsh.exe
Arguments:       -NoLogo -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\repo\tools\run-cfs-slot-sync.ps1"
Start in:        C:\path\to\repo\tools
```

---

## Related repos (our forks)

These are the companion pieces in the ecosystem:

- Filament-Sync (fork): https://github.com/pickmanmike/Filament-Sync  
- Filament-Sync-Service (fork): https://github.com/pickmanmike/Filament-Sync-Service  
- RFID for CFS (fork): https://github.com/pickmanmike/K2-RFID  
- Spoolman (fork): https://github.com/pickmanmike/Spoolman  

Upstream projects (credit where due):

- Filament-Sync upstream: https://github.com/HurricanePrint/Filament-Sync  
- Filament-Sync-Service upstream: https://github.com/HurricanePrint/Filament-Sync-Service  
- Spoolman upstream: https://github.com/Donkie/Spoolman  
- K2-RFID upstream: https://github.com/DnG-Crafts/K2-RFID  

---

## Troubleshooting

See: `docs/TROUBLESHOOTING.md`

---

## License

MIT (see `LICENSE`)
