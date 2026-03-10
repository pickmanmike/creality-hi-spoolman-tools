# Printer PC local compatibility tools

These scripts preserve the currently working Printer PC deployment pattern:

- local runtime overlay under `C:\Users\User\FilamentEcosystem-Local`
- short scheduled-task wrapper under `C:\FES`
- local Spoolman extra-field compatibility schema
- safe slot sync that skips unknown and duplicate spool IDs

They are intentionally conservative and should be treated as deployment/runtime helpers until the behavior is fully upstreamed into the default tools.
