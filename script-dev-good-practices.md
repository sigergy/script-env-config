# Production Installation Script Best Practices

Lessons extracted from auditing and hardening real-world bash install scripts.
Applies to any script that installs, configures, or modifies a Linux system.

---

## 1. Never execute remote code blindly

```bash
# ❌ No integrity check — executes whatever the URL returns
curl -fsSL https://example.com/install.sh | sudo bash

# ✅ Download, verify, inspect, then run
curl -fsSL https://example.com/install.sh -o /tmp/install.sh
echo "EXPECTED_SHA256  /tmp/install.sh" | sha256sum --check --strict -
less /tmp/install.sh
sudo bash /tmp/install.sh
```

Pin the URL to a **commit SHA**, never to a branch name — branches are mutable and can be silently replaced.

```bash
# ❌ Branch — can change at any time
https://raw.githubusercontent.com/org/repo/main/install.sh

# ✅ Immutable commit
https://raw.githubusercontent.com/org/repo/a3f7b2c1/install.sh
```

For higher-assurance environments, sign releases with GPG and verify the signature before executing.

---

## 2. Set strict shell options at the top — always

```bash
set -euo pipefail
IFS=$'\n\t'
```

| Option | What it prevents |
|---|---|
| `-e` | Script continuing silently after a failed command |
| `-u` | Undefined variables being treated as empty strings |
| `-o pipefail` | A failed command inside a pipe being swallowed |
| `IFS=$'\n\t'` | Word splitting on spaces breaking filenames and paths |

These four lines together catch the majority of silent, hard-to-debug failures.

---

## 3. Validate all inputs before using them

Never trust environment variables, arguments, or user-derived values without checking them first.

```bash
# Check the user exists before operating on it
id "${TARGET_USER}" &>/dev/null || die "User '${TARGET_USER}' does not exist."

# Sanitize: reject usernames with unexpected characters
# Prevents path traversal (e.g. "../etc/passwd") and rule injection
[[ "${TARGET_USER}" =~ ^[a-zA-Z0-9_.-]+$ ]] \
  || die "Username contains invalid characters."

# Never operate as root when the intent is a non-root user
[[ "${TARGET_USER}" != "root" ]] \
  || die "This action must not target root."
```

---

## 4. Validate config files before installing them

A broken sudoers file, nginx config, or systemd unit can lock you out of the system or crash a service. Always validate in a temp file first.

```bash
# sudoers — validate with visudo before touching /etc/sudoers.d/
TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT
echo "Defaults:${USER} timestamp_timeout=0" > "${TMP}"
visudo -cf "${TMP}" || die "Syntax error — aborting. No changes made."
install -m 0440 -o root -g root "${TMP}" /etc/sudoers.d/policy_${USER}
```

The same pattern applies to any config with a validator: `nginx -t`, `sshd -t`, `systemd-analyze verify`, etc.

---

## 5. Use a temp file with guaranteed cleanup

```bash
TMP="$(mktemp --tmpdir install.XXXXXXXXXX)"
trap 'rm -f "${TMP}"' EXIT   # runs on exit, error, or signal
```

`trap ... EXIT` fires even when the script aborts mid-run. Without it, sensitive temp files can be left behind on failure.

---

## 6. Detect $0 edge cases — pipe execution breaks script name

When a script is piped through bash (`curl ... | sudo bash`), `$0` is `bash`, not the script filename. Any message that echoes `$0` or `$(basename $0)` will print confusing or misleading instructions.

```bash
_raw="$(basename "$0")"
if [[ "${_raw}" == "bash" || "${_raw}" == "sh" ]]; then
  readonly SCRIPT_NAME="install.sh"   # canonical fallback
else
  readonly SCRIPT_NAME="${_raw}"
fi
unset _raw
```

---

## 7. Never mask failures with silent returns

```bash
# ❌ Returns 0 regardless of whether the operation succeeded
some_important_command || {
  warn "Something went wrong"
  return 0   # hides the failure from the caller and from the summary
}

# ✅ Distinguish between fatal and non-fatal failures explicitly
if some_important_command; then
  FEATURE_ENABLED=true
  ok "Feature active."
else
  warn "Could not enable feature automatically (non-fatal)."
  warn "Enable manually with: some_important_command"
  # FEATURE_ENABLED stays false — summary will reflect this
fi
```

The final summary should always reflect the real state of the system, not an optimistic assumption.

---

## 8. Make scripts idempotent

A production script must be safe to run multiple times — re-runs should produce the same result without breaking anything.

```bash
# Check before acting, not after
if [[ -f "${TARGET_FILE}" ]]; then
  log "Already configured — no changes made."
  exit 0
fi
```

This is especially important for CI/CD pipelines and configuration management tools where scripts may run on every deploy.

---

## 9. Log to syslog for audit traceability

Console output disappears. Syslog persists and is searchable.

```bash
# Log start, completion, and any destructive actions
logger -t "my-install" "started by '$(logname 2>/dev/null || echo unknown)'"
logger -t "my-install" "completed for user '${TARGET_USER}'"
logger -t "my-install" "FATAL: ${error_message}"
```

Include the invoking user — `logname` resolves the real user even under `sudo`.

---

## 10. Add timestamps to all console messages

Timestamps make it possible to correlate script output with system logs and other events.

```bash
ts() { date -u +%FT%TZ; }
log()  { printf '[INFO]  %s %s\n' "$(ts)" "$*"; }
warn() { printf '[WARN]  %s %s\n' "$(ts)" "$*" >&2; }
die()  { printf '[ERROR] %s %s\n' "$(ts)" "$*" >&2; exit 1; }
```

Use UTC (`date -u`) so timestamps are unambiguous across timezones and DST changes.

---

## 11. Check required tools before using them

Fail early with a clear message rather than failing mid-execution with a cryptic error.

```bash
for cmd in curl gpg visudo logger; do
  command -v "${cmd}" &>/dev/null \
    || die "Required command '${cmd}' not found. Install it and retry."
done
```

---

## 12. Avoid mathematical UID/range calculations

```bash
# ❌ Can overflow or produce collisions for high UIDs
local sub_start=$(( 100000 + uid * 65536 ))  # uid=1000 → 65,636,000 (overflows on some systems)

# ✅ Delegate to the tool that manages this safely
usermod --add-subuids 100000-165535 "${user}"
usermod --add-subgids 100000-165535 "${user}"
```

Let system tools handle allocation. They check for existing ranges and avoid overlaps automatically.

---

## 13. Never auto-re-execute with sudo from a temp path

```bash
# ❌ Race condition: the file at $0 could be replaced between download and re-exec
exec sudo bash "$0" "$@"

# ✅ Require explicit invocation with sudo from the start
[[ "${EUID}" -eq 0 ]] || die "Run as: sudo bash ${SCRIPT_NAME}"
```

The gap between download and re-execution is a window for a local attacker to replace the script with a malicious one.

---

## 14. Always provide a --revert option

Any script that modifies system state should be reversible.

```bash
if [[ "${REVERT}" == true ]]; then
  # Undo every change made by the install path:
  # remove files, undo config, uninstall packages, restore defaults
  revert
  exit 0
fi
```

Document explicitly what the revert does and does not undo (e.g. subuid entries are harmless to leave in place).

---

## 15. Prefer configuration management over ad-hoc scripts

For production systems managed at scale, a one-off bash script is the last resort.

| Tool | When to prefer it |
|---|---|
| **Ansible** | Multi-host, idempotent by design, readable diffs |
| **Chef / Puppet** | Continuous compliance enforcement |
| **Terraform** | Infrastructure provisioning |
| **Bash script** | Single-host, one-time bootstrapping only |

If a bash script is unavoidable, it should behave as close to an Ansible module as possible: idempotent, auditable, reversible, and validated.

---

## Quick checklist

```
[ ] URL pinned to a commit SHA, not a branch
[ ] SHA256 or GPG signature verified before execution
[ ] Script reviewed manually before running
[ ] set -euo pipefail and IFS=$'\n\t' at the top
[ ] All inputs sanitized and validated
[ ] Config files validated (visudo -cf, nginx -t, etc.) before installing
[ ] Temp files cleaned up with trap ... EXIT
[ ] $0 edge case handled for pipe execution
[ ] No silent return 0 masking real failures
[ ] Script is idempotent (safe to re-run)
[ ] Actions logged to syslog with logger
[ ] All messages include UTC timestamps
[ ] Required tools checked before use
[ ] --revert option implemented and documented
[ ] Final summary reflects actual system state
```
