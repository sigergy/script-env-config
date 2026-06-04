#!/usr/bin/env bash
# =============================================================================
# configure-sudo-timeout.sh — Production-hardened version
# =============================================================================
#
# PURPOSE
#   Disables sudo credential caching for the invoking user by writing a
#   validated drop-in rule to /etc/sudoers.d/, so that sudo always prompts
#   for a password on every invocation.
#
# USAGE
#   # Recommended (download, inspect, then run):
#   curl -fsSL https://raw.githubusercontent.com/USER/REPO/COMMIT/configure-sudo-timeout.sh \
#        -o /tmp/configure-sudo-timeout.sh
#   echo "EXPECTED_SHA256  /tmp/configure-sudo-timeout.sh" | sha256sum --check --strict -
#   less /tmp/configure-sudo-timeout.sh          # always inspect before running
#   sudo bash /tmp/configure-sudo-timeout.sh
#
#   # Undo / revert:
#   sudo bash configure-sudo-timeout.sh --revert
#
# REQUIREMENTS
#   bash >= 4, sudo, visudo, coreutils (install, mktemp, logger)
#
# EXIT CODES
#   0  — success (rule applied or already present)
#   1  — error (see log output)
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── Constants ─────────────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="1.1.0"
readonly SUDOERS_DIR="/etc/sudoers.d"
readonly LOG_TAG="configure-sudo-timeout"

# ── Logging ───────────────────────────────────────────────────────────────────
log()  { echo "[INFO]  $(date -u +%FT%TZ) ${LOG_TAG}: $*"; }
warn() { echo "[WARN]  $(date -u +%FT%TZ) ${LOG_TAG}: $*" >&2; }
die()  { echo "[ERROR] $(date -u +%FT%TZ) ${LOG_TAG}: $*" >&2; exit 1; }

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat >&2 <<EOF
Usage: sudo bash $(basename "$0") [--revert] [--help]

Options:
  --revert   Remove the drop-in rule and restore default sudo behaviour
  --help     Show this help message

Version: ${SCRIPT_VERSION}
EOF
    exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────
REVERT=false
for arg in "$@"; do
    case "${arg}" in
        --revert) REVERT=true ;;
        --help|-h) usage ;;
        *) die "Unknown argument: '${arg}'. Use --help for usage." ;;
    esac
done

# ── Preflight checks ──────────────────────────────────────────────────────────
log "Starting configure-sudo-timeout v${SCRIPT_VERSION}"

# Must run as root
[[ "$(id -u)" -eq 0 ]] \
    || die "This script must be run as root. Use: sudo bash $0"

# Required tools must be present
for cmd in visudo install logger; do
    command -v "${cmd}" &>/dev/null \
        || die "Required command '${cmd}' not found — is sudo / coreutils installed?"
done

# sudoers drop-in directory must exist
[[ -d "${SUDOERS_DIR}" ]] \
    || die "${SUDOERS_DIR} does not exist — is sudo installed?"

# ── Determine target user ─────────────────────────────────────────────────────
# SUDO_USER is set by sudo to the original invoking user.
# Never apply the policy to root itself.
TARGET_USER="${SUDO_USER:-}"

[[ -n "${TARGET_USER}" ]] \
    || die "Could not determine the invoking user. Run as: sudo bash $0"

[[ "${TARGET_USER}" != "root" ]] \
    || die "Configuring this sudo policy for root is not permitted."

# Verify the user account actually exists on this system
id "${TARGET_USER}" &>/dev/null \
    || die "User '${TARGET_USER}' does not exist on this system."

# ── Sanitize username ─────────────────────────────────────────────────────────
# Allow only characters that are valid in POSIX usernames.
# This prevents path traversal (e.g. "../etc/") and rule injection.
[[ "${TARGET_USER}" =~ ^[a-zA-Z0-9_.-]+$ ]] \
    || die "Username '${TARGET_USER}' contains invalid characters. Aborting."

# ── Derived paths ─────────────────────────────────────────────────────────────
readonly SUDOERS_FILE="${SUDOERS_DIR}/timeout_${TARGET_USER}"
readonly RULE="Defaults:${TARGET_USER} timestamp_timeout=0"

# ── Revert mode ───────────────────────────────────────────────────────────────
if [[ "${REVERT}" == true ]]; then
    if [[ -f "${SUDOERS_FILE}" ]]; then
        rm -f "${SUDOERS_FILE}"
        logger -t "${LOG_TAG}" \
            "drop-in removed for user '${TARGET_USER}' by '$(logname 2>/dev/null || echo unknown)'"
        log "Drop-in removed: ${SUDOERS_FILE}"
        log "sudo credential caching restored to system defaults for ${TARGET_USER}."
    else
        warn "No drop-in found at ${SUDOERS_FILE} — nothing to revert."
    fi
    exit 0
fi

# ── Idempotency check ─────────────────────────────────────────────────────────
# If the rule is already in place, do nothing. Safe to re-run in pipelines.
if [[ -f "${SUDOERS_FILE}" ]]; then
    log "Drop-in already exists at ${SUDOERS_FILE} — no changes made (idempotent)."
    log "To reapply: sudo rm ${SUDOERS_FILE} && sudo bash $0"
    log "To revert:  sudo bash $0 --revert"
    exit 0
fi

# ── Build and validate the rule ───────────────────────────────────────────────
# Write to a temp file and validate syntax BEFORE touching /etc/sudoers.d.
# A broken sudoers file can lock root out of sudo entirely.
TMP_FILE="$(mktemp --tmpdir sudoers_dropin.XXXXXXXXXX)"
trap 'rm -f "${TMP_FILE}"' EXIT   # always clean up temp file

echo "${RULE}" > "${TMP_FILE}"

log "Validating sudoers syntax with visudo..."
if ! visudo -cf "${TMP_FILE}" >/dev/null 2>&1; then
    die "visudo syntax check failed — aborting. No changes were made."
fi

# ── Install with strict permissions ───────────────────────────────────────────
# sudo requires drop-in files to be root:root with mode 0440.
# Any other ownership or permission causes sudo to refuse the file.
install -m 0440 -o root -g root "${TMP_FILE}" "${SUDOERS_FILE}" \
    || die "Failed to install drop-in file at ${SUDOERS_FILE}."

# ── Audit log (syslog) ────────────────────────────────────────────────────────
# Writes a traceable entry to /var/log/syslog (or equivalent).
logger -t "${LOG_TAG}" \
    "timestamp_timeout=0 set for user '${TARGET_USER}' by '$(logname 2>/dev/null || echo unknown)'"

# ── Summary ───────────────────────────────────────────────────────────────────
log "Rule installed at: ${SUDOERS_FILE}"
log "  → ${RULE}"
log "Done. sudo will now prompt for a password on every invocation for '${TARGET_USER}'."
log "To undo this change run: sudo bash $0 --revert"
