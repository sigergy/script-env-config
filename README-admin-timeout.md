# configure-sudo-timeout.sh

Bash script for Linux that forces `sudo` to prompt for a password on **every invocation**, eliminating credential caching for the user who runs it.

---

## What it does

By default, `sudo` caches credentials for 15 minutes after the first password entry. This script writes a single drop-in rule to `/etc/sudoers.d/` that sets `timestamp_timeout=0` for the invoking user, which disables that cache entirely.

```
Defaults:<username> timestamp_timeout=0
```

The rule is scoped to one user only — system-wide sudo behaviour is not affected.

---

## Requirements

| Dependency | Purpose |
|---|---|
| `bash >= 4` | Script runtime |
| `sudo` + `visudo` | Rule validation and privilege escalation |
| `coreutils` (`install`, `mktemp`, `logger`) | File handling and audit logging |

---

## Usage

### Recommended flow (download → verify → inspect → run)

```bash
# 1. Download
curl -fsSL https://raw.githubusercontent.com/USER/REPO/COMMIT/configure-sudo-timeout.sh \
     -o /tmp/configure-sudo-timeout.sh

# 2. Verify integrity
echo "EXPECTED_SHA256  /tmp/configure-sudo-timeout.sh" | sha256sum --check --strict -

# 3. Inspect before running — never skip this in production
less /tmp/configure-sudo-timeout.sh

# 4. Run
sudo bash /tmp/configure-sudo-timeout.sh
```

> ⚠️ Never use `bash <(curl ...)` in production — it executes remote code without any integrity check.

### Revert

```bash
sudo bash configure-sudo-timeout.sh --revert
```

Removes the drop-in file and restores the system default sudo behaviour for that user.

### Options

| Flag | Description |
|---|---|
| *(none)* | Apply the rule |
| `--revert` | Remove the rule |
| `--help` | Show usage |

---

## What happens internally, step by step

1. **Preflight** — verifies it is running as root, that `visudo`, `install`, and `logger` are available, and that `/etc/sudoers.d/` exists.
2. **User resolution** — reads `$SUDO_USER` (set by sudo) to identify the original invoking user. Refuses to run if the target is `root` itself.
3. **Username sanitisation** — validates the username against `^[a-zA-Z0-9_.-]+$` to prevent path traversal or rule injection.
4. **Idempotency check** — if the drop-in file already exists, exits cleanly without making any changes. Safe to re-run.
5. **Rule construction** — builds the sudoers rule in a temporary file with a random name under `/tmp`.
6. **Syntax validation** — runs `visudo -cf` against the temp file. If validation fails, the script aborts and nothing is written to `/etc/sudoers.d/`.
7. **Installation** — copies the validated file to `/etc/sudoers.d/timeout_<username>` with permissions `0440` and ownership `root:root`, as required by sudo.
8. **Audit log** — writes a traceable entry to syslog via `logger`, recording which user applied the change and when.
9. **Cleanup** — the temp file is always deleted on exit, even if the script fails mid-run (`trap ... EXIT`).

---

## Files created

| Path | Permissions | Content |
|---|---|---|
| `/etc/sudoers.d/timeout_<username>` | `0440 root:root` | `Defaults:<username> timestamp_timeout=0` |

---

## Security considerations

- The script must be run with `sudo bash script.sh`, not via `bash <(curl ...)`.
- Always pin the download URL to a specific **commit SHA**, not a branch name — branches are mutable.
- Verify the SHA256 checksum (or GPG signature) before every execution.
- `visudo -cf` prevents broken syntax from ever reaching `/etc/sudoers.d/`, which could otherwise lock `sudo` system-wide.
- All actions are logged to syslog for audit traceability.

---

## Revert / undo

```bash
sudo bash configure-sudo-timeout.sh --revert
```

Or manually:

```bash
sudo rm /etc/sudoers.d/timeout_<username>
```

---

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success — rule applied, already present, or successfully reverted |
| `1` | Error — see log output for details |

---

## Version

`1.1.0`
