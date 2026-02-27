# Creality Hi / CFS ↔ Spoolman Tools

PowerShell tools that connect the dots between:

- **Creality Hi + CFS slot state** (what’s physically loaded *right now*)
- **Spoolman** (your filament / spool inventory database)
- **Filament‑Sync** (your *filament profile catalog* for Creality printers)
- **RFID for CFS (Windows)** (programs Creality RFID tags + optionally creates spools in Spoolman)

This repo focuses on the **Spoolman side** of the ecosystem:

1) Importing Creality filament profiles into Spoolman (as Vendors + Filament templates)  
2) Keeping **Spoolman spool locations** (and optionally **remaining weight**) in sync with the printer’s CFS slots.

> Not affiliated with Creality, Donkie/Spoolman, or the other upstream projects. This is an “unofficial glue layer” project.

---

## Table of contents

- [Quick start (10 minutes)](#quick-start-10-minutes)
- [The “contract” that makes it all work](#the-contract-that-makes-it-all-work)
- [What’s in this repo](#whats-in-this-repo)
- [How it fits into the “Filament Ecosystem”](#how-it-fits-into-the-filament-ecosystem)
- [Prerequisites](#prerequisites)
- [Setup (end-to-end)](#setup-end-to-end)
- [Optional: Moonraker ⇄ Spoolman (Klipper users)](#optional-moonraker--spoolman-klipper-users)
- [Troubleshooting](#troubleshooting)
- [Security](#security)
- [Related repos (our forks)](#related-repos-our-forks)
- [License](#license)

---

## Quick start (10 minutes)

From the repo root in PowerShell:

1. **Unblock files (only if you downloaded a ZIP):**
   ```powershell
   # Unblock everything in this folder (and subfolders)
   Get-ChildItem -Recurse | Unblock-File
   ```

2. **Run the doctor (sanity checks):**
   ```powershell
   pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\doctor.ps1 -CheckDocker -TestSsh
   ```

3. **Start Spoolman** (skip if you already host it somewhere):
   ```powershell
   # example local install directory
   cd $env:USERPROFILE\spoolman
   docker compose up -d
   ```

4. **Import Creality profiles** (creates Vendors + “MASTER” filaments):
   ```powershell
   pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\sync-creality-materials-to-spoolman-masters.ps1 `
     -MaterialDatabasePath "C:\path\to\material_database.json" `
     -SpoolmanUrl "http://127.0.0.1:7912"
   ```

5. **Configure slot sync bridge:**
   ```powershell
   Copy-Item .\config\cfs-spoolman-bridge.example.json .\config\cfs-spoolman-bridge.json
   notepad .\config\cfs-spoolman-bridge.json
   ```

6. **Dry run the slot sync:**
   ```powershell
   pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\sync-cfs-slots-to-spoolman.ps1 `
     -ConfigPath .\config\cfs-spoolman-bridge.json `
     -DryRun -VerboseSlots
   ```

If the dry-run looks sane, remove `-DryRun`.

---

## The “contract” that makes it all work

To identify a *physical spool* across swaps/moves, we need a spool-level identity.

Creality’s tag format includes a 6‑character **`serialNum`** field.

**We use:**

> `RFID serialNum (6 chars)  ==  Spoolman spool.id` (zero‑padded)

Example:

- Spoolman `spool.id` = `123`
- RFID `serialNum` = `"000123"`

That gives a stable 1:1 mapping:

**CFS slot → serialNum → Spoolman spool record**

> Legacy reserve parsing is still supported (`reserveMode: "hex"` for old tags).

More detail: see `docs/ARCHITECTURE.md`.

---

## What’s in this repo

### Tools

| Script | Purpose |
|---|---|
| `tools/doctor.ps1` | Environment diagnostics (PowerShell, OpenSSH, Docker, repo layout, Spoolman reachability, optional SSH connectivity) |
| `tools/setup-spoolman-and-sync.ps1` | Helper to install/run Spoolman via Docker Compose **and** wire in the Creality→Spoolman profile sync |
| `tools/sync-creality-materials-to-spoolman-masters.ps1` | Imports Creality filament profiles as **MASTER** templates (Vendor + base Filament definitions; no per‑color variants) |
| `tools/sync-creality-materials-to-spoolman.ps1` | Imports Creality filament profiles as regular filaments (older / alternate strategy) |
| `tools/sync-cfs-slots-to-spoolman.ps1` | Reads `material_box_info.json` from printer(s) over SSH and PATCHes Spoolman spool locations (and optionally remaining weight) |
| `tools/run-cfs-slot-sync.ps1` | Wrapper for Task Scheduler: per-run logs + overlap protection |
| `tools/migrate-creality-comment-to-extra.ps1` | Migrates legacy `[CFS-RFID]` comment metadata into `spool.extra` (DryRun by default) |

### Config / examples

- `config/cfs-spoolman-bridge.example.json` – copy to `config/cfs-spoolman-bridge.json` and edit  
- `examples/docker-compose.spoolman.yml` – starter Spoolman compose file (host port `7912` → container port `8000`)

### Optional patch (legacy)

- `patches/k2-rfid-spoolman-reserve-v2-git.patch` – legacy patch that wrote `spool.id` into the tag’s `reserve` field. Kept for reference only; Identity v2 should use `serialNum = D6(spool.id)` via the Repo C fork.

---

## How it fits into the “Filament Ecosystem”

```mermaid
flowchart LR
  subgraph SlicerPC["Windows 'Printer PC'"]
    FS["Filament-Sync<br/>profile catalog → printer DB"]
    SM["Spoolman<br/>inventory + spools"]
    Tools["This repo<br/>Spoolman tools"]
    RFID["RFID for CFS (Windows)<br/>writes tags + (optionally) creates spools"]
  end

  subgraph Printer["Creality Hi / CFS"]
    Box["material_box_info.json<br/>(slot state, serialNum, reserve, remainLen)"]
    CFS["CFS hardware<br/>reads RFID tags"]
  end

  FS -->|uploads profiles| Printer
  CFS --> Box
  Tools -->|SSH read-only| Box
  Tools -->|PATCH /api/v1/spool/{id}| SM
  RFID -->|create spool + write serialNum=spool.id| SM
  RFID -->|write tag| CFS
```

---

## Prerequisites

### Required

- Windows 10/11 (this repo is optimized for Windows)
- **PowerShell 7** (`pwsh`) recommended  
  (most scripts work in Windows PowerShell 5.1 too, but `pwsh` is the “happy path”)
- **OpenSSH client** (`ssh` available in PATH)
- Network access from this PC → printer SSH (usually port 22) and → Spoolman HTTP

### Optional (but common)

- **Docker Desktop** if you want to run Spoolman locally via containers
- PowerShell module `Posh-SSH` if you must do password-based SSH *without prompts* (scheduled tasks cannot answer prompts)

> Tip: run `tools/doctor.ps1` to confirm what’s present and what’s missing.

---

## Setup (end-to-end)

### 0) Run the doctor

This catches the most common “works on my machine” issues (missing ssh, blocked scripts, bad URLs, etc.):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\doctor.ps1 -CheckDocker -TestSsh
```

To auto-fix a couple safe things (create folders, copy example config if missing, unblock scripts):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\doctor.ps1 -Fix
```

---

### 1) Install / run Spoolman (Docker Compose)

If you’re running Spoolman locally on Windows, Docker is the recommended approach.

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

Why port **7912**?

- Spoolman listens on **8000** in the container, but many Creality setups already use host port **8000** (e.g. PrintGuard). So we map host `7912 → 8000`.

Updating Spoolman later:

```powershell
docker compose pull
docker compose up -d
```

---

### 2) Import Creality profiles into Spoolman (MASTER templates)

You need a Creality-style `material_database.json` locally.

Typical sources:

- Filament‑Sync output file (recommended), or
- SCP it from the printer (advanced)

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\sync-creality-materials-to-spoolman-masters.ps1 `
  -MaterialDatabasePath "C:\path\to\material_database.json" `
  -SpoolmanUrl "http://127.0.0.1:7912"
```

If you want it to update existing MASTER filaments:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\sync-creality-materials-to-spoolman-masters.ps1 `
  -MaterialDatabasePath "C:\path\to\material_database.json" `
  -SpoolmanUrl "http://127.0.0.1:7912" `
  -UpdateExistingFilaments
```

---

### 3) Program RFID tags and create Spoolman spools

You have two common approaches:

- **Use our patched fork of the RFID tool** (recommended): it can create a Spoolman spool and then write `serialNum = spool.id`.
- **Manual:** create the spool in Spoolman, then write the serialNum field yourself (error-prone, but possible).

Either way, the goal is:

> the tag `serialNum` field contains the Spoolman `spool.id` (6 chars)

---

### 4) Configure the CFS→Spoolman bridge

1. Copy the example config:

```powershell
Copy-Item .\config\cfs-spoolman-bridge.example.json .\config\cfs-spoolman-bridge.json
```

2. Edit `.\config\cfs-spoolman-bridge.json`:

- Set `spoolmanUrl`
- Add your printer(s) under `printers`
- Prefer `sshAuth: "key"` and set `sshKey` / `sshKeyPath`

#### Config key reference (high value)

The slot sync script accepts some helpful optional keys (see script header for full list):

- `locationPrefix` (default `"CFS:"`)
- `reserveMode`: legacy reserve parsing (`"auto"` default, `"decimal"`, or `"hex"`)
- `updateRemainingWeight`: `true|false`
- `spoolmanHeaders`: for reverse proxies / auth headers
- `debugDumpDir`: dump raw JSON when parsing fails
- `materialBoxInfoPath`: override if your printer stores the file elsewhere

---

### 5) Run the CFS slot sync

Dry-run first (prints what it *would* do):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\sync-cfs-slots-to-spoolman.ps1 `
  -ConfigPath .\config\cfs-spoolman-bridge.json `
  -DryRun -VerboseSlots
```

Real run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\sync-cfs-slots-to-spoolman.ps1 `
  -ConfigPath .\config\cfs-spoolman-bridge.json `
  -ContinueOnPrinterError
```

Optional flags:

- `-UpdateRemainingWeight` (or set `"updateRemainingWeight": true` in config)
- `-ClearMissing` (clears Spoolman locations for spools that were previously seen but are no longer loaded)

> Safety: if any printer fails in a run, `-ClearMissing` is automatically skipped.

---

### 6) Schedule it (Windows Task Scheduler)

You can schedule either:

- `tools/sync-cfs-slots-to-spoolman.ps1` directly, or
- `tools/run-cfs-slot-sync.ps1` (recommended: logs + overlap protection)

Example Task Scheduler action:

```text
Program/script:  pwsh.exe
Arguments:       -NoLogo -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\repo\tools\run-cfs-slot-sync.ps1"
Start in:        C:\path\to\repo\tools
```

---

## Optional: Moonraker ⇄ Spoolman (Klipper users)

If you also run Klipper/Moonraker, Moonraker has a built-in Spoolman connector.

That is **separate** from this repo’s slot sync approach, but it can complement it nicely.

Example Moonraker config snippet:

```ini
[spoolman]
server: http://<spoolman-host>:7912
sync_rate: 5
```

See Moonraker docs for details.

---

## Troubleshooting

Start here:

- `tools/doctor.ps1`
- `docs/TROUBLESHOOTING.md`

---

## Security

Read `SECURITY.md` before you put this on the internet.

Highlights:

- Do **not** commit printer passwords / API keys.
- Prefer SSH keys over passwords.
- Host key prompts can block scheduled tasks; accept the host key once interactively (or understand the tradeoffs of disabling host key checks).

---

## Related repos (our forks)

These are the companion pieces in the ecosystem:

- Filament‑Sync (fork): https://github.com/pickmanmike/Filament-Sync  
- Filament‑Sync‑Service (fork): https://github.com/pickmanmike/Filament-Sync-Service  
- RFID for CFS (fork): https://github.com/pickmanmike/K2-RFID  
- Spoolman (fork): https://github.com/pickmanmike/Spoolman  

Upstream projects (credit where due):

- Filament‑Sync upstream: https://github.com/HurricanePrint/Filament-Sync  
- Filament‑Sync‑Service upstream: https://github.com/HurricanePrint/Filament-Sync-Service  
- Spoolman upstream: https://github.com/Donkie/Spoolman  
- K2‑RFID upstream: https://github.com/DnG-Crafts/K2-RFID  

---

## License

MIT (see `LICENSE`)
