# Build Hooks (Modloader)

Place executable `.sh` scripts in these directories to customize builds in sorted filename order:

- `pre-chroot/`: runs on the host after `debootstrap`, before entering chroot (receives `WORKSPACE_CHROOT` and all `TARGET_*` variables).
- `chroot/`: runs inside the chroot as root after `customize_image` (receives all `TARGET_*` variables).

Override the base directory with `--hooks-dir=PATH` or `HOOKS_DIR=PATH`.

## Rules

- Scripts must be executable (`chmod +x`) and end in `.sh`. Non-executable scripts are skipped with a warning.
- Any non-zero exit aborts the build; append `|| true` for optional commands.
- Keep hooks idempotent if you use `--advanced` mode to re-run stages.

## Examples

`pre-chroot/00-copy-skel.sh`:
```bash
#!/bin/bash
cp -a /path/to/my-skel/. "$WORKSPACE_CHROOT/etc/skel/"
```

`chroot/00-install-extras.sh`:
```bash
#!/bin/bash
apt-get install -y htop fastfetch
```
