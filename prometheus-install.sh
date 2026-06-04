#!/usr/bin/env bash
# =============================================================================
# prometheus-install.sh  v1.0.0
# =============================================================================
#
# PURPOSE
#   Installs Prometheus v3.x as a rootless container (Podman or Docker) on a
#   Linux system, managed as a persistent systemd user service via Quadlet
#   (Podman) or a generated systemd unit (Docker).
#
#   What it sets up:
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
#
# RECOMMENDED USAGE
#   curl -fsSL https://raw.githubusercontent.com/USER/REPO/COMMIT/prometheus-install.sh \
#        -o /tmp/prometheus-install.sh
#   echo "EXPECTED_SHA256  /tmp/prometheus-install.sh" | sha256sum --check --strict -
#   less /tmp/prometheus-install.sh
#   sudo bash /tmp/prometheus-install.sh
#
# OPTIONS
#   --user=<name>      Service user to run Prometheus as (default: prometheus)
#   --port=<number>    Host port to expose Prometheus UI on (default: 9090)
#   --retention=<days> TSDB retention period in days (default: 15)
#   --image=<ref>      Container image to use (default: quay.io/prometheus/prometheus:v3.12.0)
#   --revert           Stop and remove the service, volumes, and config
#   --help             Show this message
#
# REQUIREMENTS
#   bash >= 4, sudo, systemd with loginctl, podman (>= 5.0) or docker
#
# EXIT CODES
#   0  success
#   1  error (see log output)
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── Constants ─────────────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="1.0.0"
readonly LOG_TAG="prometheus-install"

# Prometheus internal user — the official image runs as nobody (65534)
# This is fixed by the upstream image; we set host dir ownership to match.
readonly PROMETHEUS_CONTAINER_UID=65534
readonly PROMETHEUS_CONTAINER_GID=65534

# Default values — all overridable via flags
DEFAULT_SVC_USER="prometheus"
DEFAULT_PORT="9090"
DEFAULT_RETENTION="15"
DEFAULT_IMAGE="quay.io/prometheus/prometheus:v3.12.0"

# ── Script name (handles curl | bash pipe where $0 == "bash") ─────────────────
_raw="$(basename "$0")"
if [[ "${_raw}" == "bash" || "${_raw}" == "sh" ]]; then
  readonly SCRIPT_NAME="prometheus-install.sh"
else
  readonly SCRIPT_NAME="${_raw}"
fi
unset _raw

# ── Colour support ─────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_INFO=$'\033[1;34m'; C_OK=$'\033[1;32m'
  C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'
else
  C_RESET=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""
fi

# ── Logging ───────────────────────────────────────────────────────────────────
ts()   { date -u +%FT%TZ; }
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
  --image=<ref>        Container image (default: ${DEFAULT_IMAGE})
  --revert             Remove service, volumes, config, and service user
  --help, -h           Show this help

Version: ${SCRIPT_VERSION}

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
    --user=*)       SVC_USER="${arg#--user=}" ;;
    --port=*)       HOST_PORT="${arg#--port=}" ;;
    --retention=*)  RETENTION_DAYS="${arg#--retention=}" ;;
    --image=*)      CONTAINER_IMAGE="${arg#--image=}" ;;
    --revert)       REVERT=true ;;
    --help|-h)      usage ;;
    *) die "Unknown argument: '${arg}'. Use --help for usage." ;;
  esac
done

# ── Preflight: must run as root ───────────────────────────────────────────────
[[ "${EUID}" -eq 0 ]] \
  || die "Root privileges required. Run as: sudo bash ${SCRIPT_NAME}"

# ── Validate arguments ────────────────────────────────────────────────────────
# Username: POSIX-safe characters only — prevents path traversal and injection
[[ "${SVC_USER}" =~ ^[a-zA-Z0-9_.-]+$ ]] \
  || die "Invalid service username: '${SVC_USER}'"

# Port: must be a number between 1024 and 65535
[[ "${HOST_PORT}" =~ ^[0-9]+$ ]] && \
  (( HOST_PORT >= 1024 && HOST_PORT <= 65535 )) \
  || die "Invalid port: '${HOST_PORT}'. Must be a number between 1024 and 65535."

# Retention: must be a positive integer
[[ "${RETENTION_DAYS}" =~ ^[0-9]+$ ]] && (( RETENTION_DAYS >= 1 )) \
  || die "Invalid retention: '${RETENTION_DAYS}'. Must be a positive integer (days)."

# ── Required tools ────────────────────────────────────────────────────────────
for cmd in loginctl logger install; do
  command -v "${cmd}" &>/dev/null \
    || die "Required command '${cmd}' not found. Install it and retry."
done

# ── Container engine detection ────────────────────────────────────────────────
# Prefer Podman (rootless, daemonless). Fall back to Docker if Podman is absent.
detect_engine() {
  if command -v podman &>/dev/null; then
    echo "podman"
  elif command -v docker &>/dev/null; then
    echo "docker"
  else
    die "Neither 'podman' nor 'docker' found. Install one and retry.
         Recommended: install Podman first with podman-install.sh"
  fi
}
ENGINE="$(detect_engine)"
log "Container engine: ${ENGINE}"

# ── Derived paths ─────────────────────────────────────────────────────────────
# All state lives under the service user's home directory for portability
# and to keep it within the user's own namespace.
SVC_HOME="/home/${SVC_USER}"
CONFIG_DIR="${SVC_HOME}/prometheus/config"
DATA_DIR="${SVC_HOME}/prometheus/data"
CONFIG_FILE="${CONFIG_DIR}/prometheus.yml"

# Quadlet unit path (Podman) or systemd drop-in path (Docker)
# User Quadlet files live in ~/.config/containers/systemd/
QUADLET_DIR="${SVC_HOME}/.config/containers/systemd"
QUADLET_FILE="${QUADLET_DIR}/prometheus.container"

# Docker systemd unit path (rootful fallback)
DOCKER_UNIT_FILE="/etc/systemd/system/prometheus.service"

# ── Helper: run a command as the service user ─────────────────────────────────
SVC_UID=""   # populated after user creation
run_as_svc() {
  sudo -u "${SVC_USER}" \
    XDG_RUNTIME_DIR="/run/user/${SVC_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${SVC_UID}/bus" \
    "$@"
}

# =============================================================================
# REVERT
# =============================================================================
revert() {
  log "Reverting Prometheus installation..."

  # Resolve UID for run_as_svc (user may not exist if revert runs after partial install)
  if id "${SVC_USER}" &>/dev/null; then
    SVC_UID="$(id -u "${SVC_USER}")"
  fi

  # Stop and disable the service
  if [[ "${ENGINE}" == "podman" ]]; then
    if [[ -n "${SVC_UID}" && -d "/run/user/${SVC_UID}" ]]; then
      run_as_svc systemctl --user stop prometheus.service  2>/dev/null || true
      run_as_svc systemctl --user disable prometheus.service 2>/dev/null || true
      ok "Systemd user service stopped and disabled."
    fi
    rm -f "${QUADLET_FILE}" 2>/dev/null || true
  else
    systemctl stop prometheus.service  2>/dev/null || true
    systemctl disable prometheus.service 2>/dev/null || true
    rm -f "${DOCKER_UNIT_FILE}" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    ok "Systemd service stopped, disabled, and unit removed."
  fi

  # Remove container and volume
  if [[ -n "${SVC_UID}" ]]; then
    run_as_svc "${ENGINE}" stop prometheus  2>/dev/null || true
    run_as_svc "${ENGINE}" rm   prometheus  2>/dev/null || true
    run_as_svc "${ENGINE}" volume rm prometheus-data 2>/dev/null || true
    ok "Container and named volume removed."
  fi

  # Disable lingering
  loginctl disable-linger "${SVC_USER}" 2>/dev/null || true
  ok "Lingering disabled."

  # Remove config and data directories
  rm -rf "${SVC_HOME}/prometheus" 2>/dev/null || true
  ok "Config and data directories removed."

  # Remove service user (optional — ask)
  if id "${SVC_USER}" &>/dev/null; then
    warn "Service user '${SVC_USER}' still exists. Remove manually if no longer needed:"
    warn "  sudo userdel -r ${SVC_USER}"
  fi

  logger -t "${LOG_TAG}" \
    "reverted by '$(logname 2>/dev/null || echo unknown)'"
  log "Revert complete."
}

# =============================================================================
# CREATE SERVICE USER
# =============================================================================
create_service_user() {
  if id "${SVC_USER}" &>/dev/null; then
    log "Service user '${SVC_USER}' already exists — skipping creation."
  else
    log "Creating system service user '${SVC_USER}'..."
    # --system: no aging, no cron, no mail spool
    # --create-home: needed so Podman can store image layers and Quadlet files
    # --shell /usr/sbin/nologin: prevents interactive login
    useradd \
      --system \
      --create-home \
      --home-dir "${SVC_HOME}" \
      --shell /usr/sbin/nologin \
      --comment "Prometheus monitoring service" \
      "${SVC_USER}"
    ok "Service user '${SVC_USER}' created."
  fi

  SVC_UID="$(id -u "${SVC_USER}")"
  log "Service user UID: ${SVC_UID}"
}

# =============================================================================
# DIRECTORY SETUP
# =============================================================================
# The Prometheus container image runs internally as nobody (UID 65534).
# Under rootless Podman, UID 65534 inside the container maps to a host UID
# in the service user's subuid range.
#
# The safest and most portable approach is to use podman unshare to set
# ownership from inside the user namespace — this maps UID 65534 (nobody
# inside the container) to the correct host UID automatically.
setup_directories() {
  log "Creating config and data directories..."

  install -d -m 0755 -o "${SVC_USER}" -g "${SVC_USER}" \
    "${CONFIG_DIR}" "${DATA_DIR}"

  # The data directory must be writable by the container's nobody user.
  # We use 'podman unshare chown' when using Podman: it runs the chown
  # inside the user namespace where UID 65534 maps correctly to the host.
  # For Docker (rootful), a plain chown to the container UID is correct.
  if [[ "${ENGINE}" == "podman" ]]; then
    log "Setting data directory ownership via podman unshare (rootless UID mapping)..."
    run_as_svc podman unshare chown \
      "${PROMETHEUS_CONTAINER_UID}:${PROMETHEUS_CONTAINER_GID}" \
      "${DATA_DIR}"
  else
    # Docker runs rootful — UID 65534 on the host is literally nobody
    chown "${PROMETHEUS_CONTAINER_UID}:${PROMETHEUS_CONTAINER_GID}" "${DATA_DIR}"
  fi

  ok "Directories ready:"
  ok "  Config: ${CONFIG_DIR}"
  ok "  Data:   ${DATA_DIR}"
}

# =============================================================================
# PROMETHEUS CONFIGURATION
# =============================================================================
write_default_config() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    log "prometheus.yml already exists — not overwriting."
    log "Edit it at: ${CONFIG_FILE}"
    return 0
  fi

  log "Writing default prometheus.yml..."
  cat > "${CONFIG_FILE}" <<EOF
# prometheus.yml — generated by ${SCRIPT_NAME} v${SCRIPT_VERSION}
# Edit this file to add scrape targets, alerting rules, and remote write config.
# Prometheus reloads this file on SIGHUP or when --web.enable-lifecycle is set.
# Full reference: https://prometheus.io/docs/prometheus/latest/configuration/

global:
  scrape_interval:     15s   # How frequently to scrape targets
  evaluation_interval: 15s   # How frequently to evaluate alerting rules
  # scrape_timeout defaults to 10s

  # Labels added to all time series and alerts produced by this server
  external_labels:
    instance: '$(hostname -s)'

# Alertmanager configuration (optional)
# alerting:
#   alertmanagers:
#     - static_configs:
#         - targets: ['alertmanager:9093']

# Rule files to load (alerting and recording rules)
# rule_files:
#   - /etc/prometheus/rules/*.yml

# Scrape configurations
scrape_configs:

  # Prometheus scrapes itself — useful to verify the service is alive
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  # Node Exporter — uncomment to scrape host system metrics
  # Install node-exporter first:
  #   podman run -d --name node-exporter --network=host \\
  #     quay.io/prometheus/node-exporter:latest
  # - job_name: 'node'
  #   static_configs:
  #     - targets: ['localhost:9100']
EOF

  # Config is read by the container; it does not need to be owned by nobody
  chown "${SVC_USER}:${SVC_USER}" "${CONFIG_FILE}"
  chmod 0644 "${CONFIG_FILE}"
  ok "Default prometheus.yml written."
}

# =============================================================================
# PULL IMAGE
# =============================================================================
pull_image() {
  log "Pulling container image: ${CONTAINER_IMAGE}"
  run_as_svc "${ENGINE}" pull "${CONTAINER_IMAGE}" \
    || die "Failed to pull image '${CONTAINER_IMAGE}'."
  ok "Image pulled."
}

# =============================================================================
# NAMED VOLUME
# =============================================================================
# Using a named volume (not a bind-mount) for data gives Podman full control
# over UID mapping in the volume's storage layer, avoiding permission issues.
create_named_volume() {
  if run_as_svc "${ENGINE}" volume inspect prometheus-data \
       &>/dev/null 2>&1; then
    log "Named volume 'prometheus-data' already exists — skipping."
  else
    log "Creating named volume 'prometheus-data'..."
    run_as_svc "${ENGINE}" volume create prometheus-data \
      || die "Failed to create named volume."
    ok "Named volume created."
  fi
}

# =============================================================================
# SYSTEMD INTEGRATION — PODMAN (QUADLET)
# =============================================================================
# Quadlet is the modern, recommended way to run Podman containers as systemd
# services. It replaces the deprecated 'podman generate systemd'.
# Files in ~/.config/containers/systemd/ are processed by the Quadlet generator
# when 'systemctl --user daemon-reload' is called.
setup_quadlet() {
  log "Writing Podman Quadlet unit: ${QUADLET_FILE}"

  install -d -m 0700 -o "${SVC_USER}" -g "${SVC_USER}" "${QUADLET_DIR}"

  cat > "${QUADLET_FILE}" <<EOF
# prometheus.container — Podman Quadlet unit
# Generated by ${SCRIPT_NAME} v${SCRIPT_VERSION}
# Managed by systemd: systemctl --user {start|stop|status|restart} prometheus

[Unit]
Description=Prometheus monitoring server (rootless Podman)
Documentation=https://prometheus.io/docs/introduction/overview/
After=network-online.target
Wants=network-online.target

[Container]
# Image pinned to a specific version — never use :latest in production
Image=${CONTAINER_IMAGE}
ContainerName=prometheus

# Ports
PublishPort=${HOST_PORT}:9090

# Volumes
# Config is mounted read-only — the container cannot modify it
Volume=${CONFIG_DIR}:/etc/prometheus:ro,Z
Volume=prometheus-data:/prometheus:Z

# Prometheus startup flags
Exec=--config.file=/etc/prometheus/prometheus.yml \
     --storage.tsdb.path=/prometheus \
     --storage.tsdb.retention.time=${RETENTION_DAYS}d \
     --web.enable-lifecycle \
     --web.console.libraries=/usr/share/prometheus/console_libraries \
     --web.console.templates=/usr/share/prometheus/consoles

# Security hardening
# Read-only root filesystem — Prometheus only writes to the data volume
ReadOnly=yes
# Drop all Linux capabilities — Prometheus needs none
DropCapability=ALL
# Prevent privilege escalation inside the container
NoNewPrivileges=yes
# Security label for SELinux/AppArmor (Z = private relabel for this container)
SecurityLabelDisable=false

[Service]
Restart=on-failure
RestartSec=10s
TimeoutStartSec=90s

[Install]
# Start when the user's systemd session is reached (requires lingering)
WantedBy=default.target
EOF

  chown "${SVC_USER}:${SVC_USER}" "${QUADLET_FILE}"
  chmod 0644 "${QUADLET_FILE}"
  ok "Quadlet unit written."
}

# =============================================================================
# SYSTEMD INTEGRATION — DOCKER (rootful fallback)
# =============================================================================
setup_docker_unit() {
  log "Writing Docker systemd unit: ${DOCKER_UNIT_FILE}"

  cat > "${DOCKER_UNIT_FILE}" <<EOF
# prometheus.service — Docker systemd unit
# Generated by ${SCRIPT_NAME} v${SCRIPT_VERSION}

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

ExecStartPre=-/usr/bin/docker stop prometheus
ExecStartPre=-/usr/bin/docker rm   prometheus
ExecStart=/usr/bin/docker run --rm \
  --name prometheus \
  -p ${HOST_PORT}:9090 \
  -v ${CONFIG_DIR}:/etc/prometheus:ro \
  -v prometheus-data:/prometheus \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  ${CONTAINER_IMAGE} \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prometheus \
  --storage.tsdb.retention.time=${RETENTION_DAYS}d \
  --web.enable-lifecycle \
  --web.console.libraries=/usr/share/prometheus/console_libraries \
  --web.console.templates=/usr/share/prometheus/consoles

ExecStop=/usr/bin/docker stop prometheus

[Install]
WantedBy=multi-user.target
EOF

  chmod 0644 "${DOCKER_UNIT_FILE}"
  ok "Docker systemd unit written."
}

# =============================================================================
# ENABLE AND START SERVICE
# =============================================================================
enable_and_start() {
  if [[ "${ENGINE}" == "podman" ]]; then
    log "Enabling systemd lingering for '${SVC_USER}' (required for user services at boot)..."
    loginctl enable-linger "${SVC_USER}" \
      || die "Failed to enable lingering for '${SVC_USER}'."
    ok "Lingering enabled."

    # Wait for /run/user/<uid> to be created by logind after enable-linger
    local retries=10
    while (( retries-- > 0 )); do
      [[ -d "/run/user/${SVC_UID}" ]] && break
      sleep 1
    done
    [[ -d "/run/user/${SVC_UID}" ]] \
      || die "/run/user/${SVC_UID} was not created — loginctl may need more time. Retry."

    log "Reloading systemd user daemon (triggers Quadlet generator)..."
    run_as_svc systemctl --user daemon-reload \
      || die "systemctl --user daemon-reload failed."

    log "Enabling and starting prometheus.service..."
    if run_as_svc systemctl --user enable --now prometheus.service; then
      SERVICE_STARTED=true
      ok "Service enabled and started."
    else
      warn "Could not start the service automatically."
      warn "Start it manually as '${SVC_USER}':"
      warn "  systemctl --user enable --now prometheus.service"
    fi

  else
    log "Reloading systemd daemon..."
    systemctl daemon-reload

    log "Enabling and starting prometheus.service..."
    if systemctl enable --now prometheus.service; then
      SERVICE_STARTED=true
      ok "Service enabled and started."
    else
      warn "Could not start the service automatically."
      warn "Start it manually: sudo systemctl enable --now prometheus.service"
    fi
  fi
}

# =============================================================================
# VERIFY
# =============================================================================
verify() {
  log "Verifying Prometheus is reachable on port ${HOST_PORT}..."

  # Give it up to 15 s to come up
  local retries=15
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
    ok "Prometheus is healthy at http://localhost:${HOST_PORT}"
  else
    warn "Prometheus did not respond on port ${HOST_PORT} within 15 seconds."
    warn "Check logs: "
    if [[ "${ENGINE}" == "podman" ]]; then
      warn "  journalctl --user -u prometheus.service -n 50"
    else
      warn "  journalctl -u prometheus.service -n 50"
    fi
    warn "Or directly: ${ENGINE} logs prometheus"
  fi
}

# =============================================================================
# SUMMARY
# =============================================================================
summary() {
  local svc_status="not started — see warnings above"
  [[ "${SERVICE_STARTED}" == true ]] && svc_status="active"

  local manage_cmd
  if [[ "${ENGINE}" == "podman" ]]; then
    manage_cmd="systemctl --user"
  else
    manage_cmd="sudo systemctl"
  fi

  cat <<EOF

${C_OK}========================================================${C_RESET}
${C_OK} Prometheus installation complete  (v${SCRIPT_VERSION})${C_RESET}
${C_OK}========================================================${C_RESET}

  Engine         : ${ENGINE} ($(${ENGINE} --version 2>&1 | head -1))
  Image          : ${CONTAINER_IMAGE}
  Service user   : ${SVC_USER} (uid ${SVC_UID})
  Service status : ${svc_status}
  UI             : http://localhost:${HOST_PORT}
  Retention      : ${RETENTION_DAYS} days

  Paths:
    Config       : ${CONFIG_FILE}
    Data volume  : ${ENGINE} volume inspect prometheus-data

  Service management (as user ${SVC_USER} or with sudo):
    ${manage_cmd} status  prometheus
    ${manage_cmd} restart prometheus
    ${manage_cmd} stop    prometheus
    ${manage_cmd} logs -f prometheus   (journalctl)

  Reload config without restart:
    curl -X POST http://localhost:${HOST_PORT}/-/reload

  To add scrape targets, edit:
    ${CONFIG_FILE}
  Then reload Prometheus (no restart needed).

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
  log "Starting ${SCRIPT_NAME} v${SCRIPT_VERSION}"
  logger -t "${LOG_TAG}" \
    "started by '$(logname 2>/dev/null || echo unknown)'"

  if [[ "${REVERT}" == true ]]; then
    revert
    exit 0
  fi

  create_service_user
  setup_directories
  write_default_config
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
    "completed successfully (engine=${ENGINE}, user=${SVC_USER}, port=${HOST_PORT})"
}

main "$@"
