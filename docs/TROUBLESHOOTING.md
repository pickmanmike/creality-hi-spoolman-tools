# Troubleshooting

## Spoolman reachability errors

The slot sync script tries a couple of probe URLs and then uses the Spoolman REST API.

Things to check:

1. Is Spoolman running?
   - If using Docker: `docker ps`
2. Is the host/port correct in `spoolmanUrl`?
   - Example: `http://127.0.0.1:7912`
3. Can you reach the API in a browser or with curl?
   - `http://127.0.0.1:7912/api/v1/info`
   - `http://127.0.0.1:7912/api/v1/health`

If you run Spoolman behind a reverse proxy, you may need:

- `spoolmanHeaders` (API key / auth header)
- or a different base URL (depending on how you published the API path)

---

## SSH failures / timeouts

Common causes:

- Printer IP changed (DHCP).
- SSH/root access not enabled on the printer.
- Wrong port (some setups change it from 22).
- Host key prompts blocking a scheduled task.

### Host key prompts + scheduled tasks

When you use key auth, the script runs `ssh` with `BatchMode=yes`.
That is good for automation, but it means **ssh cannot prompt** to accept a new host key.

Fix options:

**Option A (recommended):** connect once interactively from the same Windows account:

```powershell
ssh -i C:\path\to\key root@PRINTER_IP
```

Accept the host key prompt once. Then scheduled runs should succeed.

**Option B (automation tradeoff):** disable strict host key checking via config:

```json
"sshExtraArgs": ["-o","StrictHostKeyChecking=no","-o","UserKnownHostsFile=NUL"]
```

This is less secure (MITM risk), but it avoids prompts.

---

## No updates happen (spools “skipped”)

The slot sync only updates spools when it can map:

1. slot → RFID `reserve` (6 chars)  
2. reserve → `spool.id` (decimal or hex)  
3. `spool.id` exists in Spoolman

If reserve is `"000000"` or missing, nothing can be matched.

---

## Remaining weight sync doesn't change anything

Remaining sync requires:

- `updateRemainingWeight: true` (config) or `-UpdateRemainingWeight`
- Spoolman must have a usable “base weight”:
  - `spool.initial_weight` if present, else
  - `filament.weight` (per-filament default)

If neither exists, the script will skip remaining updates.

---

## ClearMissing safety behavior

If you run with `-ClearMissing` and *any* printer fails to fetch/parse,
the script automatically skips ClearMissing to avoid clearing spools due to partial data.

This is intentional.
