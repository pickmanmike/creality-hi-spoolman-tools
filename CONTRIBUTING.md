# Contributing

Thanks for helping make this ecosystem less cursed. 🙂

## Quick guidelines

- Keep scripts runnable on **Windows PowerShell 5.1** where possible.
- Prefer *read-only* interactions with the printer (SSH `cat` of JSON files).
- Avoid committing secrets:
  - printer passwords
  - API keys
  - local IPs if you can avoid it
- If you add a new config key, update:
  - `config/cfs-spoolman-bridge.example.json`
  - `README.md`

## Development notes

- Linting is done via PSScriptAnalyzer in GitHub Actions (see `.github/workflows`).
- Please include a short description + example usage when adding new scripts or switches.
