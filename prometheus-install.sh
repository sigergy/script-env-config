#!/usr/bin/env bash
# =============================================================================
# prometheus-install.sh  v1.1.0
# =============================================================================
#
# PURPOSE
#   Installs Prometheus as a rootless container (Podman or Docker) on a Linux
#   system, managed as a persistent systemd user service via Quadlet (Podman)
#   or a generated systemd unit (Docker).
#
#   What it sets up:
#     - Dedicated system service user with correct subuid/subgid mapping
#     - Named volume for persistent TSDB data
#     - Host directory for prometheus.yml configuration
#     - Systemd user service that starts at boot and survives logouts
#     - Correct file ownership for the container's internal nobody (UID 65534)
#
# SECURITY PHILOSOPHY
#   - Container runs as nobody (UID 65534) inside — no root inside or outside
#   - Podman rootless mode: container escape gives at most the service user's
#     unprivileged host account
#   - Config is mounted read-only (:ro) — the container cannot modify it
#   - Data directory is isolated under the service user's home
#   - Container hardened: read-only rootfs, all capabilities dropped,
#     no-new-privileges
#
# RECOMMENDED USAGE (never pipe curl directly to bash)
#   curl -fsSL https://raw.githubusercontent.com/USER/REPO/COMMIT/prometheus-install.sh \
#        -o /tmp/prometheus-install.sh
#   echo "EXPECTED_SHA256  /tmp/prometheus-install.sh" | sha256sum --check --strict -
#   less /tmp/prometheus-install.sh
#   sudo bash /tmp/prometheus-install.sh
#
# OPTIONS
#   --user=<name>      Service user to run Prometheus as (default: prometheus)
#   --port=<number>    Host port to expose the UI on (default: 9090)
#   --retention=<days> TSDB retention period in days (default: 15)
#   --image=<ref>      Container image reference (default: see PROMETHEUS_VERSION)
#   --revert           Stop and fully remove the service, volumes, and config
#   --help             Show this message
#
# REQUIREMENTS
#   bash >= 4, sudo, systemd with loginctl, curl, ss (iproute2)
#   podman >= 5.0  OR  docker
#
# EXIT CODES
#   0  success
#   1  error (see log output)
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── Version constants ─────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="1.1.0"
readonly LOG_TAG="prometheus-install"

# Prometheus release to install.
# Update PROMETHEUS_VERSION when a new release is available:
#   https://github.com/prometheus/prometheus/releases
readonly PROMETHEUS_VERSION="v3.12.0"
readonly DEFAULT_IMAGE="quay.io/prometheus/prometheus:${PROMETHEUS_VERSION}"

# Prometheus internal UID — the official image always runs as nobody (65534).
# This is fixed upstream; we must match host directory ownership to this.
readonly PROMETHEUS_CONTAINER_UID=65534
readonly PROMETHEUS_CONTAINER_GID=65534

# ── Default values (all overridable via CLI flags) ────────────────────────────
DEFAULT_SVC_USER="prometheus"
DEFAULT_PORT="9090"
DEFAULT_RETENTION="15"

# ── Script name — handles curl | bash pipe where $0 == "bash" ────────────────
_raw="$(basename "$0")"
if [[ "${_raw}" == "bash" || "${_raw}" == "sh" ]]; then
  readonly SCRIPT_NAME="prometheus-install.sh"
else
  readonly SCRIPT_NAME="${_raw}"
fi
unset _raw

# ── Colour support (disabled when not writing to a terminal) ──────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_INFO=$'\033[1;34m'; C_OK=$'\033[1;32m'
  C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'
else
  C_RESET=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""
fi

# ── Logging — all messages include UTC timestamps ─────────────────────────────
ts()   { date -u +%FT%TZ; }   # ISO-8601 UTC: 2026-06-04T13:24:05Z
log()  { printf '%s[INFO]%s  %s  %s\n' "$C_INFO"  "$C_RESET" "$(ts)" "$*"; }
ok()   { printf '%s[ OK ]%s  %s  %s\n' "$C_OK"    "$C_RESET" "$(ts)" "$*"; }
warn() { printf '%s[WARN]%s  %s  %s\n' "$C_WARN"  "$C_RESET" "$(ts)" "$*" >&2; }
die()  { printf '%s[ERR ]%s  %s  %s\n' "$C_ERR"   "$C_RESET" "$(ts)" "$*" >&2
         logger -t "${LOG_TAG}" "FATAL: $*" 2>/dev/null || true
         exit 1; }

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat >&2 <<EOF
Usage: sudo bash ${SCRIPT_NAME} [options]

Options:
  --user=<name>        Service user (default: ${DEFAULT_SVC_USER})
  --port=<number>      Host port for the Prometheus UI (default: ${DEFAULT_PORT})
  --retention=<days>   TSDB data retention in days (default: ${DEFAULT_RETENTION})
  --image=<ref>        Container image reference (default: ${DEFAULT_IMAGE})
  --revert             Remove service, volumes, config, and service user
  --help, -h           Show this help

Version: ${SCRIPT_VERSION}   Prometheus: ${PROMETHEUS_VERSION}

Examples:
  sudo bash ${SCRIPT_NAME}
  sudo bash ${SCRIPT_NAME} --port=9091 --retention=30
  sudo bash ${SCRIPT_NAME} --revert
EOF
  exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────
REVERT=false
SVC_USER="${DEFAULT_SVC_USER}"
HOST_PORT="${DEFAULT_PORT}"
RETENTION_DAYS="${DEFAULT_RETENTION}"
CONTAINER_IMAGE="${DEFAULT_IMAGE}"
SERVICE_STARTED=false

for arg in "$@"; do
  case "${arg}" in
    --user=*)      SVC_USER="${arg#--user=}" ;;
    --port=*)      HOST_PORT="${arg#--port=}" ;;
    --retention=*) RETENTION_DAYS="${arg#--retention=}" ;;
    --image=*)     CONTAINER_IMAGE="${arg#--image=}" ;;
    --revert)      REVERT=true ;;
    --help|-h)     usage ;;
    *) die "Unknown argument: '${arg}'. Use --help for usage." ;;
  esac
done

# ── Preflight: must run as root ───────────────────────────────────────────────
[[ "${EUID}" -eq 0 ]] \
  || die "Root privileges required. Run as: sudo bash ${SCRIPT_NAME}"

# ── Input validation ──────────────────────────────────────────────────────────

# Username: POSIX allowlist — prevents path traversal and config injection
[[ "${SVC_USER}" =~ ^[a-zA-Z0-9_.-]+$ ]] \
  || die "Invalid service username: '${SVC_USER}'. Only [a-zA-Z0-9_.-] allowed."

# Never run as root itself
[[ "${SVC_USER}" != "root" ]] \
  || die "Service username cannot be 'root'."

# Port: numeric, unprivileged range only
[[ "${HOST_PORT}" =~ ^[0-9]+$ ]] \
  && (( HOST_PORT >= 1024 && HOST_PORT <= 65535 )) \
  || die "Invalid port: '${HOST_PORT}'. Must be a number 1024–65535."

# Retention: positive integer
[[ "${RETENTION_DAYS}" =~ ^[0-9]+$ ]] && (( RETENTION_DAYS >= 1 )) \
  || die "Invalid retention: '${RETENTION_DAYS}'. Must be a positive integer (days)."

# Image reference: allowlist of characters valid in OCI image references.
# Prevents shell injection if the value is passed into heredocs or commands.
[[ "${CONTAINER_IMAGE}" =~ ^[a-zA-Z0-9./_:@-]+$ ]] \
  || die "Invalid image reference: '${CONTAINER_IMAGE}'.
         Only alphanumerics and [./_:@-] are allowed."

# ── Required tools preflight ──────────────────────────────────────────────────
# Checked before any state-modifying operation — fail clean, not mid-install.
for cmd in curl ss loginctl logger install useradd usermod; do
  command -v "${cmd}" &>/dev/null \
    || die "Required command '${cmd}' not found. Install it and retry."
done

# ── Container engine detection ────────────────────────────────────────────────
# Prefer Podman (rootless, daemonless). Fall back to Docker if absent.
detect_engine() {
  if command -v podman &>/dev/null; then
    echo "podman"
  elif command -v docker &>/dev/null; then
    echo "docker"
  else
    die "Neither 'podman' nor 'docker' found. Install one and retry.
         Recommended: run podman-install.sh first."
  fi
}
ENGINE="$(detect_engine)"

# Capture engine version now — used safely in summary() without inline $()
ENGINE_VERSION="$("${ENGINE}" --version 2>&1 | head -1 || echo 'unknown')"

# Resolve Docker binary path — never hardcode /usr/bin/docker
DOCKER_BIN="$(command -v docker 2>/dev/null || echo '/usr/bin/docker')"

log "Container engine: ${ENGINE} — ${ENGINE_VERSION}"

# ── Port availability check ───────────────────────────────────────────────────
# Fail before touching anything if the port is already in use.
if ss -tlnp 2>/dev/null | grep -q ":${HOST_PORT} "; then
  die "Port ${HOST_PORT} is already in use.
       Choose a different port with: --port=<n>"
fi

# ── SELinux detection — controls :Z volume flag ───────────────────────────────
# :Z requests a private SELinux relabel of the volume. On systems without
# SELinux it is harmless but generates warnings; on SELinux systems it is
# required for the container to read/write the mounted directory.
SELINUX_ACTIVE=false
if command -v getenforce &>/dev/null \
   && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
  SELINUX_ACTIVE=true
fi

vol_flags() {
  # Usage: vol_flags [extra_flags]
  # Appends ,Z only when SELinux is enforcing/permissive
  local base="${1:-}"
  if [[ "${SELINUX_ACTIVE}" == true ]]; then
    echo "${base},Z"
  else
    echo "${base}"
  fi
}

log "SELinux active: ${SELINUX_ACTIVE}"

# ── Derived paths ─────────────────────────────────────────────────────────────
SVC_HOME="/home/${SVC_USER}"
CONFIG_DIR="${SVC_HOME}/prometheus/config"
DATA_DIR="${SVC_HOME}/prometheus/data"
CONFIG_FILE="${CONFIG_DIR}/prometheus.yml"

QUADLET_DIR="${SVC_HOME}/.config/containers/systemd"
QUADLET_FILE="${QUADLET_DIR}/prometheus.container"
DOCKER_UNIT_FILE="/etc/systemd/system/prometheus.service"

# ── Service user UID (populated after create_service_user) ───────────────────
SVC_UID=""

# ── Helper: run a command as the service user ─────────────────────────────────
# Guards against SVC_UID being empty — would produce invalid XDG_RUNTIME_DIR
run_as_svc() {
  [[ -n "${SVC_UID}" ]] \
    || die "BUG: run_as_svc called before SVC_UID was set."
  # cd to / before exec so podman's re-exec inside the user namespace does not
  # inherit the caller's cwd (e.g. /home/admin-rcev with mode 0700) and fail
  # with "cannot chdir ... Permission denied / Error: setting up the process".
  sudo -u "${SVC_USER}" \
    HOME="${SVC_HOME}" \
    XDG_RUNTIME_DIR="/run/user/${SVC_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${SVC_UID}/bus" \
    bash -c 'cd / && exec "$@"' _ "$@"
}

# =============================================================================
# REVERT
# =============================================================================
revert() {
  log "Reverting Prometheus installation..."

  # Resolve UID before any user-context operations
  if id "${SVC_USER}" &>/dev/null; then
    SVC_UID="$(id -u "${SVC_USER}")"
    log "Service user '${SVC_USER}' found (uid ${SVC_UID})."
  else
    warn "Service user '${SVC_USER}' not found — skipping user-context steps."
  fi

  # ── Stop and disable service ────────────────────────────────────────────────
  if [[ "${ENGINE}" == "podman" ]]; then
    if [[ -n "${SVC_UID}" && -d "/run/user/${SVC_UID}" ]]; then
      run_as_svc systemctl --user stop    prometheus.service 2>/dev/null || true
      run_as_svc systemctl --user disable prometheus.service 2>/dev/null || true
      run_as_svc systemctl --user daemon-reload              2>/dev/null || true
      ok "Systemd user service stopped, disabled, and daemon reloaded."
    else
      warn "User runtime dir not available — service may already be stopped."
    fi
    rm -f "${QUADLET_FILE}" 2>/dev/null || true
    ok "Quadlet unit file removed."
  else
    systemctl stop    prometheus.service 2>/dev/null || true
    systemctl disable prometheus.service 2>/dev/null || true
    rm -f "${DOCKER_UNIT_FILE}"          2>/dev/null || true
    systemctl daemon-reload              2>/dev/null || true
    ok "Systemd service stopped, disabled, unit removed, daemon reloaded."
  fi

  # ── Remove container and named volume ───────────────────────────────────────
  if [[ -n "${SVC_UID}" ]]; then
    run_as_svc "${ENGINE}" stop   prometheus        2>/dev/null || true
    run_as_svc "${ENGINE}" rm     prometheus        2>/dev/null || true
    run_as_svc "${ENGINE}" volume rm prometheus-data 2>/dev/null || true
    ok "Container and named volume removed."
  fi

  # ── Disable lingering ────────────────────────────────────────────────────────
  loginctl disable-linger "${SVC_USER}" 2>/dev/null || true
  ok "Lingering disabled."

  # ── Remove config and data directories ──────────────────────────────────────
  rm -rf "${SVC_HOME}/prometheus" 2>/dev/null || true
  ok "Config and data directories removed."

  # ── Service user ────────────────────────────────────────────────────────────
  # Deliberately not auto-removing — the operator should confirm.
  if id "${SVC_USER}" &>/dev/null; then
    warn "Service user '${SVC_USER}' still exists. Remove manually if no longer needed:"
    warn "  sudo userdel -r ${SVC_USER}"
  fi

  logger -t "${LOG_TAG}" "reverted by '$(logname 2>/dev/null || echo unknown)'"
  log "Revert complete."
}

# =============================================================================
# CREATE SERVICE USER
# =============================================================================
create_service_user() {
  if id "${SVC_USER}" &>/dev/null; then
    log "Service user '${SVC_USER}' already exists — skipping creation (idempotent)."
  else
    log "Creating system service user '${SVC_USER}'..."
    # --system      : no password aging, no cron job, no mail spool
    # --create-home : Podman needs a home dir for image layers and Quadlet files
    # --shell nologin: prevents interactive login
    useradd \
      --system \
      --create-home \
      --home-dir "${SVC_HOME}" \
      --shell /usr/sbin/nologin \
      --comment "Prometheus monitoring service" \
      "${SVC_USER}" \
      || die "Failed to create service user '${SVC_USER}'."
    ok "Service user '${SVC_USER}' created."
  fi

  SVC_UID="$(id -u "${SVC_USER}")"
  log "Service user UID: ${SVC_UID}"

  # ── subuid / subgid — required for Podman rootless UID mapping ───────────────
  # useradd --system does NOT always add subuid/subgid entries.
  # Without them, podman unshare and container UID mapping will fail.
  if ! grep -q "^${SVC_USER}:" /etc/subuid 2>/dev/null; then
    log "Allocating subuid range for '${SVC_USER}'..."
    usermod --add-subuids 100000-165535 "${SVC_USER}" \
      || die "Failed to set subuid for '${SVC_USER}'."
    ok "subuid range allocated."
  else
    log "subuid entry already exists for '${SVC_USER}' — skipping."
  fi

  if ! grep -q "^${SVC_USER}:" /etc/subgid 2>/dev/null; then
    log "Allocating subgid range for '${SVC_USER}'..."
    usermod --add-subgids 100000-165535 "${SVC_USER}" \
      || die "Failed to set subgid for '${SVC_USER}'."
    ok "subgid range allocated."
  else
    log "subgid entry already exists for '${SVC_USER}' — skipping."
  fi
}

# =============================================================================
# ENABLE LINGERING (Podman only — must run before any podman unshare call)
# =============================================================================
# loginctl enable-linger creates /run/user/<uid> and keeps the user's systemd
# session alive without an interactive login. This directory must exist before
# 'podman unshare' is called, because podman unshare itself needs the runtime
# dir to initialise the user namespace.
#
# Called immediately after create_service_user, BEFORE setup_directories.
enable_linger() {
  [[ "${ENGINE}" == "podman" ]] || return 0   # Docker does not need this

  log "Enabling systemd lingering for '${SVC_USER}' (required before podman unshare)..."
  loginctl enable-linger "${SVC_USER}"     || die "Failed to enable lingering for '${SVC_USER}'."
  ok "Lingering enabled."

  # Wait up to 15 s for /run/user/<uid> to be created by logind.
  # Without this directory podman unshare fails immediately with
  # "lstat /run/user/<uid>: no such file or directory".
  log "Waiting for /run/user/${SVC_UID} to be created by logind..."
  local retries=15
  while (( retries-- > 0 )); do
    [[ -d "/run/user/${SVC_UID}" ]] && break
    sleep 1
  done

  [[ -d "/run/user/${SVC_UID}" ]]     || die "/run/user/${SVC_UID} was not created within 15 s.
            This can happen when logind is not fully running (e.g. containers).
            Try: loginctl enable-linger ${SVC_USER} && sleep 5 && re-run."

  ok "/run/user/${SVC_UID} is ready."
}

# =============================================================================
# DIRECTORY SETUP
# =============================================================================
# The Prometheus container runs internally as nobody (UID 65534).
# Under rootless Podman, UID 65534 inside the container maps to a host UID
# within the service user's subuid range.
#
# 'podman unshare chown' runs the chown inside the user namespace where the
# UID mapping is active — no manual subuid arithmetic needed.
# enable_linger() MUST have run before this function (ensures /run/user/<uid>).
setup_directories() {
  log "Creating config and data directories..."

  install -d -m 0755 -o "${SVC_USER}" -g "${SVC_USER}" \
    "${CONFIG_DIR}" "${DATA_DIR}" \
    || die "Failed to create directories."

  if [[ "${ENGINE}" == "podman" ]]; then
    log "Setting data directory ownership via podman unshare (rootless UID mapping)..."
    # podman unshare needs HOME pointing to the service user's home so it can
    # find its config. We also set --chdir to avoid inheriting the calling
    # user's cwd (which the service user may not have permission to access).
    # XDG_RUNTIME_DIR is intentionally NOT passed here — it is not needed for
    # unshare and causes "Error: setting up the process" in some environments.
    sudo -u "${SVC_USER}" env HOME="${SVC_HOME}" \
      bash -c 'cd / && exec podman unshare chown "$1:$2" "$3"' \
      _ "${PROMETHEUS_CONTAINER_UID}" "${PROMETHEUS_CONTAINER_GID}" "${DATA_DIR}" \
      || die "podman unshare chown failed.
              Verify subuid/subgid entries exist for '${SVC_USER}':
                grep ${SVC_USER} /etc/subuid /etc/subgid"
  else
    # Docker is rootful — UID 65534 on the host IS nobody
    chown "${PROMETHEUS_CONTAINER_UID}:${PROMETHEUS_CONTAINER_GID}" "${DATA_DIR}" \
      || die "chown on data directory failed."
  fi

  ok "Directories ready:"
  ok "  Config : ${CONFIG_DIR}"
  ok "  Data   : ${DATA_DIR}"
}

# =============================================================================
# PROMETHEUS CONFIGURATION
# =============================================================================
# FIX #1: heredoc uses 'EOF' (quoted) to block all shell expansion inside
#         the YAML content. Dynamic values are injected via sed afterwards,
#         which is explicit, auditable, and safe.
write_default_config() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    log "prometheus.yml already exists — not overwriting (idempotent)."
    log "Edit it at: ${CONFIG_FILE}"
    return 0
  fi

  log "Writing default prometheus.yml..."

  # Write to a temp file first — never write directly to the final path.
  # If the process is interrupted mid-write the destination stays intact.
  local tmp_cfg
  tmp_cfg="$(mktemp --tmpdir prometheus-yml.XXXXXXXXXX)"
  trap 'rm -f "${tmp_cfg}"' INT TERM EXIT

  # Quoted heredoc — zero shell expansion inside.
  # Placeholder INSTALL_HOSTNAME is replaced explicitly below.
  cat > "${tmp_cfg}" << 'YAML_EOF'
# prometheus.yml
# Edit this file to add scrape targets, alerting rules, and remote write config.
# Reload without restart: curl -X POST http://localhost:9090/-/reload
# Full reference: https://prometheus.io/docs/prometheus/latest/configuration/

global:
  scrape_interval:     15s
  evaluation_interval: 15s
  # scrape_timeout defaults to 10s

  external_labels:
    instance: 'INSTALL_HOSTNAME'

# alerting:
#   alertmanagers:
#     - static_configs:
#         - targets: ['alertmanager:9093']

# rule_files:
#   - /etc/prometheus/rules/*.yml

scrape_configs:

  # Prometheus scrapes itself
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  # Node Exporter — uncomment to scrape host system metrics
  # Install: podman run -d --name node-exporter --network=host \
  #            quay.io/prometheus/node-exporter:latest
  # - job_name: 'node'
  #   static_configs:
  #     - targets: ['localhost:9100']
YAML_EOF

  # Inject the hostname explicitly — the only dynamic value in this file
  local host_short
  host_short="$(hostname -s 2>/dev/null || echo 'localhost')"
  sed -i "s/INSTALL_HOSTNAME/${host_short}/" "${tmp_cfg}"

  # Move atomically to the final destination
  mv "${tmp_cfg}" "${CONFIG_FILE}"
  chown "${SVC_USER}:${SVC_USER}" "${CONFIG_FILE}"
  chmod 0644 "${CONFIG_FILE}"

  # Remove the trap now that tmp_cfg has been moved
  trap - INT TERM EXIT

  ok "Default prometheus.yml written to ${CONFIG_FILE}."
}

# =============================================================================
# PULL IMAGE
# =============================================================================
pull_image() {
  log "Pulling container image: ${CONTAINER_IMAGE}"
  run_as_svc "${ENGINE}" pull "${CONTAINER_IMAGE}" \
    || die "Failed to pull image '${CONTAINER_IMAGE}'.
            Check network connectivity and image reference."
  ok "Image pulled: ${CONTAINER_IMAGE}"
}

# =============================================================================
# NAMED VOLUME
# =============================================================================
# Named volume gives the engine full control over UID mapping in the storage
# layer, avoiding the permission pitfalls of plain bind-mounts for data.
create_named_volume() {
  if run_as_svc "${ENGINE}" volume inspect prometheus-data &>/dev/null 2>&1; then
    log "Named volume 'prometheus-data' already exists — skipping (idempotent)."
    return 0
  fi
  log "Creating named volume 'prometheus-data'..."
  run_as_svc "${ENGINE}" volume create prometheus-data \
    || die "Failed to create named volume 'prometheus-data'."
  ok "Named volume 'prometheus-data' created."
}

# =============================================================================
# SYSTEMD INTEGRATION — PODMAN (QUADLET)
# =============================================================================
# Quadlet is the modern replacement for the deprecated 'podman generate systemd'.
# The .container file is placed in ~/.config/containers/systemd/ and converted
# to a real systemd unit when 'systemctl --user daemon-reload' runs.
#
# FIX #3: The Quadlet INI file is written via a quoted heredoc to prevent any
# accidental shell expansion. Dynamic values are written into a separate
# variables section, then the file is assembled with explicit substitutions.
#
# FIX #3b: The Exec= line uses separate Exec= directives per flag instead of
# a single line with backslash continuations — backslash continuation is a
# bash syntax; INI files do not support it and Quadlet would misparse the flags.
setup_quadlet() {
  if [[ -f "${QUADLET_FILE}" ]]; then
    log "Quadlet unit already exists — not overwriting (idempotent)."
    log "To regenerate: remove ${QUADLET_FILE} and re-run."
    return 0
  fi

  log "Writing Podman Quadlet unit: ${QUADLET_FILE}"
  install -d -m 0700 -o "${SVC_USER}" -g "${SVC_USER}" "${QUADLET_DIR}" \
    || die "Failed to create Quadlet directory."

  # Compose volume flag strings based on SELinux detection
  local vol_config vol_data
  vol_config="$(vol_flags "ro")"
  vol_data="$(vol_flags "")"
  # Strip leading comma if no extra flags
  vol_data="${vol_data#,}"

  # Write to temp file first, then install atomically with correct permissions
  local tmp_unit
  tmp_unit="$(mktemp --tmpdir prometheus-quadlet.XXXXXXXXXX)"
  trap 'rm -f "${tmp_unit}"' INT TERM EXIT

  # Quoted heredoc — no shell expansion. Values are injected via printf below.
  cat > "${tmp_unit}" << 'UNIT_EOF'
# prometheus.container — Podman Quadlet unit
# Managed by systemd: systemctl --user {start|stop|status|restart} prometheus

[Unit]
Description=Prometheus monitoring server (rootless Podman)
Documentation=https://prometheus.io/docs/introduction/overview/
After=network-online.target
Wants=network-online.target

[Container]
Image=QUADLET_IMAGE
ContainerName=prometheus

PublishPort=QUADLET_PORT:9090

# Config mounted read-only — container cannot modify it
Volume=QUADLET_CONFIG_DIR:/etc/prometheus:QUADLET_VOL_CONFIG
Volume=prometheus-data:/prometheus:QUADLET_VOL_DATA

# Each Exec= entry is a separate Prometheus flag.
# Quadlet does not support backslash line continuation (this is INI, not bash).
Exec=--config.file=/etc/prometheus/prometheus.yml
Exec=--storage.tsdb.path=/prometheus
Exec=--storage.tsdb.retention.time=QUADLET_RETENTIONd
Exec=--web.enable-lifecycle
Exec=--web.console.libraries=/usr/share/prometheus/console_libraries
Exec=--web.console.templates=/usr/share/prometheus/consoles

# Security hardening
ReadOnly=yes
DropCapability=ALL
NoNewPrivileges=yes

[Service]
Restart=on-failure
RestartSec=10s
TimeoutStartSec=90s

[Install]
WantedBy=default.target
UNIT_EOF

  # Inject all dynamic values explicitly via sed — no heredoc expansion risk
  sed -i \
    -e "s|QUADLET_IMAGE|${CONTAINER_IMAGE}|g"         \
    -e "s|QUADLET_PORT|${HOST_PORT}|g"                \
    -e "s|QUADLET_CONFIG_DIR|${CONFIG_DIR}|g"         \
    -e "s|QUADLET_VOL_CONFIG|${vol_config}|g"         \
    -e "s|QUADLET_VOL_DATA|${vol_data}|g"             \
    -e "s|QUADLET_RETENTION|${RETENTION_DAYS}|g"      \
    "${tmp_unit}"

  install -m 0644 -o "${SVC_USER}" -g "${SVC_USER}" \
    "${tmp_unit}" "${QUADLET_FILE}" \
    || die "Failed to install Quadlet unit file."

  rm -f "${tmp_unit}"
  trap - INT TERM EXIT

  ok "Quadlet unit written: ${QUADLET_FILE}"
}

# =============================================================================
# SYSTEMD INTEGRATION — DOCKER (rootful fallback)
# =============================================================================
# FIX #7: Docker binary path resolved at runtime via command -v, not hardcoded.
# FIX #3: Same quoted-heredoc + sed pattern used for safety.
setup_docker_unit() {
  if [[ -f "${DOCKER_UNIT_FILE}" ]]; then
    log "Docker systemd unit already exists — not overwriting (idempotent)."
    return 0
  fi

  log "Writing Docker systemd unit: ${DOCKER_UNIT_FILE}"

  local tmp_unit
  tmp_unit="$(mktemp --tmpdir prometheus-docker-unit.XXXXXXXXXX)"
  trap 'rm -f "${tmp_unit}"' INT TERM EXIT

  cat > "${tmp_unit}" << 'UNIT_EOF'
# prometheus.service — Docker systemd unit
# Generated by UNIT_SCRIPT_NAME vUNIT_SCRIPT_VERSION

[Unit]
Description=Prometheus monitoring server (Docker)
Documentation=https://prometheus.io/docs/introduction/overview/
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=simple
Restart=on-failure
RestartSec=10s
TimeoutStartSec=90s

ExecStartPre=-UNIT_DOCKER_BIN stop prometheus
ExecStartPre=-UNIT_DOCKER_BIN rm   prometheus
ExecStart=UNIT_DOCKER_BIN run --rm \
  --name prometheus \
  -p UNIT_PORT:9090 \
  -v UNIT_CONFIG_DIR:/etc/prometheus:ro \
  -v prometheus-data:/prometheus \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  UNIT_IMAGE \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prometheus \
  --storage.tsdb.retention.time=UNIT_RETENTIONd \
  --web.enable-lifecycle \
  --web.console.libraries=/usr/share/prometheus/console_libraries \
  --web.console.templates=/usr/share/prometheus/consoles

ExecStop=UNIT_DOCKER_BIN stop prometheus

[Install]
WantedBy=multi-user.target
UNIT_EOF

  sed -i \
    -e "s|UNIT_SCRIPT_NAME|${SCRIPT_NAME}|g"           \
    -e "s|UNIT_SCRIPT_VERSION|${SCRIPT_VERSION}|g"     \
    -e "s|UNIT_DOCKER_BIN|${DOCKER_BIN}|g"             \
    -e "s|UNIT_PORT|${HOST_PORT}|g"                    \
    -e "s|UNIT_CONFIG_DIR|${CONFIG_DIR}|g"             \
    -e "s|UNIT_IMAGE|${CONTAINER_IMAGE}|g"             \
    -e "s|UNIT_RETENTION|${RETENTION_DAYS}|g"          \
    "${tmp_unit}"

  install -m 0644 -o root -g root "${tmp_unit}" "${DOCKER_UNIT_FILE}" \
    || die "Failed to install Docker systemd unit."

  rm -f "${tmp_unit}"
  trap - INT TERM EXIT

  ok "Docker systemd unit written: ${DOCKER_UNIT_FILE}"
}

# =============================================================================
# ENABLE AND START SERVICE
# =============================================================================
enable_and_start() {
  if [[ "${ENGINE}" == "podman" ]]; then
    # Lingering was already enabled by enable_linger() which runs before
    # setup_directories(). /run/user/<uid> is guaranteed to exist at this point.
    log "Reloading systemd user daemon (triggers Quadlet generator)..."
    run_as_svc systemctl --user daemon-reload \
      || die "systemctl --user daemon-reload failed."

    log "Enabling and starting prometheus.service..."
    if run_as_svc systemctl --user enable --now prometheus.service; then
      SERVICE_STARTED=true
      ok "Service enabled and started."
    else
      warn "Could not start the service automatically (non-fatal)."
      warn "Start manually as '${SVC_USER}':"
      warn "  systemctl --user enable --now prometheus.service"
    fi


  else
    log "Reloading systemd daemon..."
    systemctl daemon-reload

    log "Enabling and starting prometheus.service (Docker)..."
    if systemctl enable --now prometheus.service; then
      SERVICE_STARTED=true
      ok "Service enabled and started."
    else
      warn "Could not start the service automatically (non-fatal)."
      warn "Start manually: sudo systemctl enable --now prometheus.service"
    fi
  fi
}

# =============================================================================
# VERIFY
# =============================================================================
verify() {
  log "Waiting for Prometheus to become healthy on port ${HOST_PORT}..."

  local retries=20
  local reachable=false
  while (( retries-- > 0 )); do
    if curl -fsSL --max-time 2 \
         "http://localhost:${HOST_PORT}/-/healthy" &>/dev/null; then
      reachable=true
      break
    fi
    sleep 1
  done

  if [[ "${reachable}" == true ]]; then
    ok "Prometheus is healthy: http://localhost:${HOST_PORT}"
  else
    warn "Prometheus did not respond on port ${HOST_PORT} within 20 seconds."
    warn "Check service logs:"
    if [[ "${ENGINE}" == "podman" ]]; then
      warn "  journalctl --user -u prometheus.service -n 50"
    else
      warn "  journalctl -u prometheus.service -n 50"
    fi
    warn "Or container logs: ${ENGINE} logs prometheus"
  fi
}

# =============================================================================
# SUMMARY
# =============================================================================
# ENGINE_VERSION was captured before any state changes — safe to use here.
summary() {
  local svc_status="not started — see warnings above"
  [[ "${SERVICE_STARTED}" == true ]] && svc_status="active"

  local manage_cmd
  [[ "${ENGINE}" == "podman" ]] \
    && manage_cmd="systemctl --user" \
    || manage_cmd="sudo systemctl"

  cat <<EOF

${C_OK}========================================================${C_RESET}
${C_OK} Prometheus installation complete  (v${SCRIPT_VERSION})${C_RESET}
${C_OK}========================================================${C_RESET}

  Engine         : ${ENGINE} (${ENGINE_VERSION})
  Image          : ${CONTAINER_IMAGE}
  Service user   : ${SVC_USER} (uid ${SVC_UID})
  Service status : ${svc_status}
  UI             : http://localhost:${HOST_PORT}
  Retention      : ${RETENTION_DAYS} days
  SELinux labels : ${SELINUX_ACTIVE}

  Paths:
    Config file  : ${CONFIG_FILE}
    Data volume  : ${ENGINE} volume inspect prometheus-data

  Service management:
    ${manage_cmd} status  prometheus
    ${manage_cmd} restart prometheus
    ${manage_cmd} stop    prometheus

  View logs:
    journalctl ${ENGINE_JOURNAL_FLAG} -u prometheus.service -f

  Reload config without restarting (--web.enable-lifecycle is active):
    curl -X POST http://localhost:${HOST_PORT}/-/reload

  To add scrape targets, edit the config file and reload:
    \${EDITOR:-vi} ${CONFIG_FILE}
    curl -X POST http://localhost:${HOST_PORT}/-/reload

  To uninstall:
    curl -fsSL https://raw.githubusercontent.com/USER/REPO/COMMIT/${SCRIPT_NAME} \\
         -o /tmp/${SCRIPT_NAME}
    sudo bash /tmp/${SCRIPT_NAME} --revert

EOF
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  log "Starting ${SCRIPT_NAME} v${SCRIPT_VERSION} (Prometheus ${PROMETHEUS_VERSION})"
  logger -t "${LOG_TAG}" \
    "started by '$(logname 2>/dev/null || echo unknown)'"

  if [[ "${REVERT}" == true ]]; then
    revert
    exit 0
  fi

  # Determine journalctl flag for summary — set before summary() is called
  ENGINE_JOURNAL_FLAG=""
  [[ "${ENGINE}" == "podman" ]] && ENGINE_JOURNAL_FLAG="--user"

  create_service_user    # creates user + subuid/subgid
  enable_linger          # enable-linger + wait for /run/user/<uid> (Podman only)
  setup_directories      # creates dirs + correct UID ownership via podman unshare
  write_default_config   # writes config atomically via temp file

  # Pull image and create volume BEFORE writing service units.
  # If pull fails, no service unit is left behind in a broken state.
  pull_image
  create_named_volume

  if [[ "${ENGINE}" == "podman" ]]; then
    setup_quadlet
  else
    setup_docker_unit
  fi

  enable_and_start
  verify
  summary

  logger -t "${LOG_TAG}" \
    "completed (engine=${ENGINE}, user=${SVC_USER}, port=${HOST_PORT})"
}

main "$@"
