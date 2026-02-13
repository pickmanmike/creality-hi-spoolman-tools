# Security notes

## Credentials

Do **not** commit:

- printer SSH passwords
- Spoolman API keys / reverse proxy headers
- any personally identifiable info

Use environment variables where possible, e.g.:

- `CFS_SSH_PASSWORD` for password-based SSH (supported by the CFS slot sync script)

## SSH host key checking

Disabling host key checking makes automation easier but reduces security.

Preferred: connect once interactively to accept the host key into `known_hosts`.

Only disable strict host key checking if you understand the tradeoff.
