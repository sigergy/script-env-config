# Production Installation Script Best Practices

> Lessons extracted from auditing and hardening real-world bash install scripts.
> Applies to any script that installs, configures, or modifies a Linux system.

---

## Table of Contents

1. [Choose the right tool first](#1-choose-the-right-tool-first)
2. [Never execute remote code blindly](#2-never-execute-remote-code-blindly)
3. [Set strict shell options at the top — always](#3-set-strict-shell-options-at-the-top--always)
4. [Request only the minimum privileges needed](#4-request-only-the-minimum-privileges-needed)
5. [Validate all inputs before using them](#5-validate-all-inputs-before-using-them)
6. [Validate config files before installing them](#6-validate-config-files-before-installing-them)
7. [Set correct permissions on installed files](#7-set-correct-permissions-on-installed-files)
8. [Use a temp file with guaranteed cleanup](#8-use-a-temp-file-with-guaranteed-cleanup)
9. [Detect $0 edge cases — pipe execution breaks script name](#9-detect-0-edge-cases--pipe-execution-breaks-script-name)
10. [Never mask failures with silent returns](#10-never-mask-failures-with-silent-returns)
11. [Make scripts idempotent](#11-make-scripts-idempotent)
12. [Log to syslog for audit traceability](#12-log-to-syslog-for-audit-traceability)
13. [Add timestamps to all console messages](#13-add-timestamps-to-all-console-messages)
14. [Check required tools before using them](#14-check-required-tools-before-using-them)
15. [Avoid mathematical UID/range calculations](#15-avoid-mathematical-uidrange-calculations)
16. [Never auto-re-execute with sudo from a temp path](#16-never-auto-re-execute-with-sudo-from-a-temp-path)
17. [Always provide a --revert option](#17-always-provide-a---revert-option)
18. [Quick checklist](#quick-checklist)

---

## 1. Choose the right tool first

> **Risk:** unnecessary complexity, fragility, and maintenance burden from solving
> a configuration-management problem with a bash script.

For production systems managed at scale, a one-off bash script is the last resort.
Before writing a single line of bash, ask whether a dedicated tool fits better:

| Tool | When to prefer it |
|---|---|
| **Ansible** | Multi-host, idempotent by design, readable diffs, no agent required |
| **Chef / Puppet** | Continuous compliance enforcement, drift detection |
| **Terraform** | Infrastructure provisioning (VMs, networks, cloud resources) |
| **Bash script** | Single-host, one-time bootstrapping where no tooling is available |

If a bash script is unavoidable, it must behave as close to an Ansible module as
possible: **idempotent, auditable, reversible, and validated**.

---

## 2. Never execute remote code blindly

> **Risk:** supply-chain attack, MITM, or a compromised repository silently
> executing arbitrary code as root.

```bash
# ❌ No integrity check — executes whatever the URL returns at that moment
curl -fsSL https://example.com/install.sh | sudo bash

# ✅ Download, verify integrity, inspect, then run
curl -fsSL https://example.com/install.sh -o /tmp/install.sh
echo "EXPECTED_SHA256  /tmp/install.sh" | sha256sum --check --strict -
less /tmp/install.sh          # always read before running
sudo bash /tmp/install.sh
```

Pin the download URL to an **immutable commit SHA**, never to a branch name.
Branches are mutable — their content can be replaced without changing the URL.

```text
# ❌ Branch — can be silently rewritten at any time
https://raw.githubusercontent.com/org/repo/main/install.sh

# ✅ Immutable — tied to a specific commit forever
https://raw.githubusercontent.com/org/repo/a3f7b2c1e8d94f0b/install.sh
```

### GPG signature verification (higher-assurance environments)

SHA256 verifies integrity but not **authorship** — an attacker who controls the
server also controls the published hash. GPG verification proves the release was
signed by a known private key:

```bash
# Publisher side — sign the script
gpg --armor --detach-sign install.sh         # produces install.sh.asc

# Consumer side — verify before running
curl -fsSL https://example.com/install.sh     -o /tmp/install.sh
curl -fsSL https://example.com/install.sh.asc -o /tmp/install.sh.asc
gpg --verify /tmp/install.sh.asc /tmp/install.sh \
  && sudo bash /tmp/install.sh \
  || { echo "GPG verification FAILED — aborting"; exit 1; }
```

Import and trust the publisher's public key once, out of band, before using this flow.

---

## 3. Set strict shell options at the top — always

> **Risk:** silent failures, undefined variables treated as empty strings,
> errors inside pipes going undetected.

```bash
set -euo pipefail
IFS=$'\n\t'
```

| Option | What it prevents |
|---|---|
| `-e` | Script continuing silently after a failed command |
| `-u` | Undefined variables being treated as empty strings |
| `-o pipefail` | A failed command inside a pipe being swallowed |
| `IFS=$'\n\t'` | Word splitting on spaces corrupting filenames and paths |

These four lines together catch the majority of silent, hard-to-debug failures.
Place them immediately after the shebang, before any other code.

---

## 4. Request only the minimum privileges needed

> **Risk:** unnecessary root exposure; operations that should run as a normal user
> being performed as root, widening the blast radius of any mistake.

A script that needs root for installation should not run everything as root.
Separate privileged operations (package installation, writing system files) from
user-space operations (enabling systemd user services, configuring dotfiles).

```bash
# ✅ Run root operations as root, user operations as the original user
run_as_user() {
  sudo -u "${TARGET_USER}" \
    XDG_RUNTIME_DIR="/run/user/$(id -u "${TARGET_USER}")" \
    "$@"
}

# Root section: install packages
apt-get install -y podman

# User section: enable user socket — must NOT run as root
run_as_user systemctl --user enable --now podman.socket
```

Never re-escalate to root mid-script for operations that don't need it.
Require `sudo` at invocation time, not mid-execution via `exec sudo bash "$0"`.

---

## 5. Validate all inputs before using them

> **Risk:** path traversal, rule injection into config files, operating on
> non-existent or unintended system users.

Never trust environment variables, arguments, or user-derived values without
explicit validation. Check existence, type, and shape before use.

```bash
# Verify the target user exists on this system
id "${TARGET_USER}" &>/dev/null \
  || die "User '${TARGET_USER}' does not exist on this system."

# Sanitize: reject characters that are not valid in POSIX usernames.
# Prevents "../etc/passwd" path traversal and injection into sudoers rules.
[[ "${TARGET_USER}" =~ ^[a-zA-Z0-9_.-]+$ ]] \
  || die "Username '${TARGET_USER}' contains invalid characters."

# Never apply a non-root policy to root itself
[[ "${TARGET_USER}" != "root" ]] \
  || die "This operation must not target root."
```

Apply the same pattern to every external value: file paths, version strings,
package names, URLs passed as arguments.

---

## 6. Validate config files before installing them

> **Risk:** a broken sudoers file silently locks root out of `sudo`; a bad nginx
> config crashes the web server; a malformed systemd unit prevents a service from
> starting — all without any warning at install time.

Always write to a temp file and validate it **before** touching the real path.
Every major system config has a validator; always use it.

```bash
TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT

echo "Defaults:${TARGET_USER} timestamp_timeout=0" > "${TMP}"

# Validate syntax — abort entirely if it fails, never partial-write
visudo -cf "${TMP}" \
  || die "sudoers syntax check failed — aborting. No changes were made."

# Install only after validation passes
install -m 0440 -o root -g root "${TMP}" "/etc/sudoers.d/policy_${TARGET_USER}"
```

| Config type | Validator command |
|---|---|
| sudoers | `visudo -cf <file>` |
| nginx | `nginx -t -c <file>` |
| sshd | `sshd -t -f <file>` |
| systemd unit | `systemd-analyze verify <file>` |
| cron | `crontab -l` (after install, or parse manually) |

---

## 7. Set correct permissions on installed files

> **Risk:** wrong permissions cause subtle, silent failures. `sudo` silently
> ignores drop-in files that are not `0440 root:root`. `/etc/profile.d/` scripts
> with wrong permissions are skipped by some shells without any warning.

```bash
# sudoers drop-ins: must be 0440 root:root
# sudo ignores files with ANY other permission — no error, no warning
install -m 0440 -o root -g root "${TMP}" /etc/sudoers.d/myrule

# profile.d scripts: must be readable by all users
chmod 0644 /etc/profile.d/myenv.sh

# Executable wrappers: owned by root, not writable by others
install -m 0755 -o root -g root mywrapper /usr/local/bin/mywrapper
```

As a rule: **system files should be owned by root and not writable by anyone else.**
Use `install` instead of `cp` — it sets ownership and permissions atomically.

Also, be careful with the syntax of files placed in `/etc/profile.d/`. These are
sourced by `/bin/sh`, not `/bin/bash`. Write them in **POSIX sh**, not bash:

```sh
# ❌ Bashism — breaks on /bin/sh
export VAR="${UID:-$(id -u)}"

# ✅ POSIX sh — safe everywhere
_uid=$(id -u)
export VAR="${_uid}"
unset _uid
```

---

## 8. Use a temp file with guaranteed cleanup

> **Risk:** script aborts mid-run and leaves sensitive data (credentials, partial
> config files, sudoers rules) in `/tmp` indefinitely.

```bash
# GNU/Linux (production Linux servers)
TMP="$(mktemp --tmpdir install.XXXXXXXXXX)"

# Portable fallback (macOS, BSD — --tmpdir is GNU-only)
# TMP="$(mktemp /tmp/install.XXXXXXXXXX)"

# Handle EXIT, INT (Ctrl+C), and TERM (kill signal)
trap 'rm -f "${TMP}"' INT TERM EXIT
```

`trap ... EXIT` alone covers normal exits and `set -e` aborts.
Adding `INT` and `TERM` also handles interruptions from `Ctrl+C` or `kill`,
preventing partial state from being left behind during destructive operations.

---

## 9. Detect $0 edge cases — pipe execution breaks script name

> **Risk:** instructions printed to the user reference `bash` instead of the
> script filename, producing nonsensical output like `sudo bash bash --revert`.

When a script is piped through bash (`curl ... | sudo bash`), `$0` is `bash`.
Any message that echoes `$0` or `$(basename $0)` will mislead the user.

```bash
_raw="$(basename "$0")"
if [[ "${_raw}" == "bash" || "${_raw}" == "sh" ]]; then
  readonly SCRIPT_NAME="install.sh"   # canonical fallback
else
  readonly SCRIPT_NAME="${_raw}"
fi
unset _raw
```

This also serves as an implicit nudge: the revert instructions shown at the end
of the script will always include the full download URL, reinforcing the
recommended workflow over blind piping.

---

## 10. Never mask failures with silent returns

> **Risk:** the script reports success and prints a clean summary while a critical
> component (socket, service, config) was never actually enabled.

```bash
# ❌ Returns 0 regardless of success — the summary will lie
some_important_command || {
  warn "Something went wrong"
  return 0       # hides the failure; caller and summary see "ok"
}

# ✅ Distinguish fatal from non-fatal failures explicitly
if some_important_command; then
  FEATURE_ENABLED=true
  ok "Feature active."
else
  warn "Could not enable feature automatically (non-fatal)."
  warn "Enable manually with: some_important_command"
  # FEATURE_ENABLED stays false — the summary reflects this accurately
fi
```

Use a state variable (e.g. `SOCKET_ENABLED=false`) that the summary reads at the
end. The summary should describe the **actual** post-install state, not what was
intended.

---

## 11. Make scripts idempotent

> **Risk:** re-running a non-idempotent script on a CI/CD pipeline or after a
> partial failure corrupts state, duplicates entries, or overwrites valid config.

```bash
# Check before acting, not after
if [[ -f "${TARGET_FILE}" ]]; then
  log "Already configured at ${TARGET_FILE} — no changes made."
  log "To reapply: remove it first with: sudo rm ${TARGET_FILE}"
  exit 0
fi
```

Idempotency rules:
- Check for existing state before every write operation
- Appending to files (e.g. `.bashrc`) requires deduplication checks
- Package installs are idempotent by default (`apt-get install` is a no-op if already installed)
- `usermod --add-subuids` must be guarded with a `grep` check first

---

## 12. Log to syslog for audit traceability

> **Risk:** console output is lost after the terminal closes. Without an audit
> trail, it is impossible to reconstruct who ran the script, when, and with
> what outcome.

```bash
# Log key events: start, completion, reversals, and fatal errors
logger -t "my-install" "started by '$(logname 2>/dev/null || echo unknown)' for user '${TARGET_USER}'"
logger -t "my-install" "completed successfully for user '${TARGET_USER}'"
logger -t "my-install" "reverted by '$(logname 2>/dev/null || echo unknown)'"
logger -t "my-install" "FATAL: ${error_message}"
```

`logname` resolves the original invoking user even under `sudo` — always prefer
it over `$USER` or `whoami` for audit purposes.

Entries are written to `/var/log/syslog` (Debian/Ubuntu) or `/var/log/messages`
(RHEL) and are searchable with `grep my-install /var/log/syslog`.

---

## 13. Add timestamps to all console messages

> **Risk:** without timestamps it is impossible to correlate script output with
> system logs, other concurrent processes, or a timeline of events.

```bash
ts()   { date -u +%FT%TZ; }
log()  { printf '[INFO]  %s %s\n' "$(ts)" "$*"; }
warn() { printf '[WARN]  %s %s\n' "$(ts)" "$*" >&2; }
die()  { printf '[ERROR] %s %s\n' "$(ts)" "$*" >&2; exit 1; }
```

Use UTC (`date -u`) — local time is ambiguous across timezones and DST
transitions. ISO 8601 format (`%FT%TZ`) sorts lexicographically and is
unambiguous in logs.

---

## 14. Check required tools before using them

> **Risk:** the script fails mid-execution with a cryptic `command not found`
> error after having already made partial changes to the system.

```bash
for cmd in curl gpg visudo install logger loginctl; do
  command -v "${cmd}" &>/dev/null \
    || die "Required command '${cmd}' not found. Install it and retry."
done
```

Run this check **before** any state-modifying operation. A clean preflight
failure is always better than a half-applied change.

---

## 15. Avoid mathematical UID/range calculations

> **Risk:** manual UID arithmetic produces values that overflow on 32-bit kernels,
> collide with ranges already assigned to other users, or exceed the valid range
> for `/etc/subuid` entries (max ~4.2 billion, but kernel limits apply earlier).

```bash
# ❌ Overflows for high UIDs — uid=1000 → start = 100000 + 1000*65536 = 65,636,000
# Exceeds the 32-bit subuid limit on some older kernels; also collides between users
local sub_start=$(( 100000 + uid * 65536 ))

# ✅ Delegate to usermod — it allocates ranges safely, checks existing entries,
#    and avoids overlaps between users automatically
if ! grep -q "^${user}:" /etc/subuid; then
  usermod --add-subuids 100000-165535 "${user}"
fi
if ! grep -q "^${user}:" /etc/subgid; then
  usermod --add-subgids 100000-165535 "${user}"
fi
```

Let system tools manage allocation. They have the context to do it correctly.

---

## 16. Never auto-re-execute with sudo from a temp path

> **Risk:** race condition — the window between download and re-execution is
> long enough for a local attacker to replace the script at `$0` with a
> malicious one that then runs as root.

```bash
# ❌ TOCTOU race condition
if [[ "${EUID}" -ne 0 ]]; then
  exec sudo bash "$0" "$@"    # $0 could be replaced before this line runs
fi

# ✅ Require sudo at invocation time — no re-execution, no race
[[ "${EUID}" -eq 0 ]] \
  || die "Root privileges required. Run as: sudo bash ${SCRIPT_NAME}"
```

The correct invocation model is: download → verify → inspect → `sudo bash script.sh`.
The script should never try to elevate itself.

---

## 17. Always provide a --revert option

> **Risk:** no documented undo path forces operators to manually reverse changes
> under pressure, increasing the chance of mistakes during an incident.

```bash
# Argument parsing
for arg in "$@"; do
  case "${arg}" in
    --revert) REVERT=true ;;
    --help)   usage ;;
    *)        die "Unknown argument: '${arg}'" ;;
  esac
done

# Revert function mirrors every action in the install path
revert() {
  # Disable services, remove files, uninstall packages, restore defaults
  systemctl --user disable --now myservice.socket  2>/dev/null || true
  rm -f /etc/profile.d/myenv.sh /usr/local/bin/mywrapper
  apt-get remove -y mypackage 2>/dev/null || true
  logger -t "my-install" "reverted by '$(logname 2>/dev/null || echo unknown)'"
}

[[ "${REVERT}" == true ]] && { revert; exit 0; }
```

Document what the revert **does not** undo — some changes (like `/etc/subuid`
entries or installed CA certificates) are harmless to leave in place and safer
not to touch during a rollback.

---

## Quick checklist

Use this before publishing or running any production installation script.

```text
DESIGN
[ ] Evaluated whether Ansible/Chef/Terraform fits better than bash
[ ] Minimum privileges: root only where unavoidable, user-space ops run as the target user
[ ] --revert option implemented and documented
[ ] Script version defined as a readonly constant

DOWNLOAD & INTEGRITY
[ ] URL pinned to a commit SHA, not a branch name
[ ] SHA256 checksum (or GPG signature) verified before execution
[ ] Script reviewed manually (less script.sh) before running
[ ] No curl ... | sudo bash in usage instructions

SHELL SAFETY
[ ] set -euo pipefail at the top
[ ] IFS=$'\n\t' set
[ ] trap 'cleanup' INT TERM EXIT for temp file removal
[ ] $0 edge case handled for pipe execution (bash/$0 fallback)

INPUTS & VALIDATION
[ ] All arguments and env vars sanitized and validated
[ ] Username/path inputs checked against an allowlist regex
[ ] Target user verified to exist before operating on it
[ ] Config files validated with their tool (visudo, nginx -t, sshd -t…) before install

FILES & PERMISSIONS
[ ] Temp files use mktemp and are cleaned up on all exit paths
[ ] Installed files use install -m <mode> -o root -g root (not cp)
[ ] /etc/sudoers.d/ files are exactly 0440 root:root
[ ] /etc/profile.d/ scripts are written in POSIX sh (no bashisms)

RELIABILITY
[ ] No silent return 0 masking real failures
[ ] State variables track actual outcome (not assumed success)
[ ] Script is idempotent — safe to re-run without breaking anything
[ ] Required tools checked with command -v before use
[ ] No manual UID/GID arithmetic — delegated to usermod or similar

OBSERVABILITY
[ ] All console messages include UTC timestamps
[ ] Key events logged to syslog with logger -t
[ ] Final summary reflects actual system state, not intended state
[ ] Invoking user captured with logname (not $USER or whoami)
```
