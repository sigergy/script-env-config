#!/usr/bin/env bash
# =============================================================================
# podman-install.sh  v1.3.0
# =============================================================================
#
# PURPOSE
#   Installs and configures Podman in ROOTLESS mode on a Linux production
#   environment, with Docker command compatibility.
#   Always installs the LATEST stable Podman available for the running distro,
#   adding upstream repositories where the distro's own repos lag behind.
#
# SECURITY PHILOSOPHY
#   - sudo is required ONLY to install packages and prepare the system.
#   - Podman runs WITHOUT elevated privileges (rootless).
#
# RECOMMENDED USAGE (always inspect before running):
#   curl -fsSL https://raw.githubusercontent.com/USER/REPO/COMMIT/podman-install.sh \
#        -o /tmp/podman-install.sh
#   echo "EXPECTED_SHA256  /tmp/podman-install.sh" | sha256sum --check --strict -
#   less /tmp/podman-install.sh
#   sudo bash /tmp/podman-install.sh
#
# OPTIONS
#   --revert             Uninstall Podman and remove all configuration
#   --user=<username>    Target user for rootless setup (default: $SUDO_USER)
#   --help               Show this help message
#
# OPTIONAL ENVIRONMENT VARIABLES
#   PODMAN_USER=name     Equivalent to --user=<name>
#
# REQUIREMENTS
#   bash >= 4, sudo, systemd with loginctl, coreutils
#   Supported distros: Debian/Ubuntu, RHEL/Fedora/CentOS, openSUSE, Arch, Alpine
#
# EXIT CODES
#   0  success
#   1  error (see log output)
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── Constants ─────────────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="1.3.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_TAG="podman-install"
readonly PODMAN_MIN_MAJOR=5    # minimum major version considered "latest stable"
SOCKET_ENABLED=false           # updated during enable_user_socket()

# ── Colour support (only when writing to a real terminal) ─────────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_INFO=$'\033[1;34m'; C_OK=$'\033[1;32m'
  C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'
else
  C_RESET=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""
fi

# ── Logging ───────────────────────────────────────────────────────────────────
ts()   { date -u +%FT%TZ; }
log()  { printf '%s[INFO]%s %s %s\n'  "$C_INFO"  "$C_RESET" "$(ts)" "$*"; }
ok()   { printf '%s[ OK ]%s %s %s\n'  "$C_OK"    "$C_RESET" "$(ts)" "$*"; }
warn() { printf '%s[WARN]%s %s %s\n'  "$C_WARN"  "$C_RESET" "$(ts)" "$*" >&2; }
die()  { printf '%s[ERR ]%s %s %s\n'  "$C_ERR"   "$C_RESET" "$(ts)" "$*" >&2
         logger -t "${LOG_TAG}" "FATAL: $*" 2>/dev/null || true
         exit 1; }

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat >&2 <<EOF
Usage: sudo bash ${SCRIPT_NAME} [--user=<username>] [--revert] [--help]

Options:
  --user=<name>   User to configure rootless Podman for (default: \$SUDO_USER)
  --revert        Uninstall Podman and remove all configuration
  --help, -h      Show this message

Version: ${SCRIPT_VERSION}
EOF
  exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────
REVERT=false
PODMAN_USER_ARG=""

for arg in "$@"; do
  case "${arg}" in
    --revert)    REVERT=true ;;
    --user=*)    PODMAN_USER_ARG="${arg#--user=}" ;;
    --help|-h)   usage ;;
    *) die "Unknown argument: '${arg}'. Use --help for usage." ;;
  esac
done

# ── Preflight: must run as root ───────────────────────────────────────────────
[[ "${EUID}" -eq 0 ]] \
  || die "Root privileges required. Run as: sudo bash ${SCRIPT_NAME}"

# ── Resolve target user ───────────────────────────────────────────────────────
# Priority: --user flag > PODMAN_USER env var > SUDO_USER (set by sudo)
TARGET_USER="${PODMAN_USER_ARG:-${PODMAN_USER:-${SUDO_USER:-}}}"

[[ -n "${TARGET_USER}" ]] \
  || die "Could not determine the target user.
         Run as: sudo bash ${SCRIPT_NAME}
         Or pass: sudo bash ${SCRIPT_NAME} --user=myuser"

[[ "${TARGET_USER}" != "root" ]] \
  || die "Rootless Podman cannot be configured for root itself."

id "${TARGET_USER}" &>/dev/null \
  || die "User '${TARGET_USER}' does not exist on this system."

# Sanitize: only POSIX-safe username characters
[[ "${TARGET_USER}" =~ ^[a-zA-Z0-9_.-]+$ ]] \
  || die "Username '${TARGET_USER}' contains invalid characters."

TARGET_UID="$(id -u "${TARGET_USER}")"
log "Target user for rootless Podman: ${TARGET_USER} (uid ${TARGET_UID})"

# ── Helper: run a command as the target user with a valid user session ────────
run_as_user() {
  sudo -u "${TARGET_USER}" \
    XDG_RUNTIME_DIR="/run/user/${TARGET_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" \
    "$@"
}

# ── Distro detection ──────────────────────────────────────────────────────────
[[ -r /etc/os-release ]] \
  || die "/etc/os-release not found — unsupported distribution."

# shellcheck disable=SC1091
. /etc/os-release
DISTRO_ID="${ID:-}"
DISTRO_LIKE="${ID_LIKE:-}"
DISTRO_VERSION_ID="${VERSION_ID:-0}"
log "Distribution detected: ${PRETTY_NAME:-$DISTRO_ID}"

pkg_family() {
  case " ${DISTRO_ID} ${DISTRO_LIKE} " in
    *" debian "*|*" ubuntu "*)            echo "debian" ;;
    *" rhel "*|*" fedora "*|*" centos "*) echo "rhel"   ;;
    *" suse "*|*" opensuse "*)            echo "suse"   ;;
    *" arch "*)                           echo "arch"   ;;
    *" alpine "*)                         echo "alpine" ;;
    *)                                    echo "unknown" ;;
  esac
}
FAMILY="$(pkg_family)"

# ── Required tools check ─────────────────────────────────────────────────────
for cmd in curl gpg logger; do
  command -v "${cmd}" &>/dev/null \
    || die "Required command '${cmd}' not found. Please install it and retry."
done

# =============================================================================
# UPSTREAM REPOSITORY SETUP
# =============================================================================
# Strategy (per distro):
#
#   Debian/Ubuntu >= 24.04 (Noble+):  official repos already have Podman 5.x
#   Debian/Ubuntu < 24.04:            add alvistack OBS repo (actively maintained
#                                     upstream packaging, Kubic is discontinued)
#   RHEL/CentOS Stream 9+/Fedora 38+: official repos have 5.x — no extra repo needed
#   RHEL/CentOS older:                add EPEL + advise; Copr podman-next exists
#                                     but is explicitly NOT recommended for production
#                                     by the Podman team itself
#   openSUSE Tumbleweed:              always latest upstream
#   openSUSE Leap:                    add devel:kubic:libcontainers:stable OBS repo
#   Arch:                             always latest upstream
#   Alpine edge/3.17+:                latest from community repo
# =============================================================================

# ── Helper: add a GPG key safely ─────────────────────────────────────────────
add_apt_gpg_key() {
  local url="$1" dest="$2"
  log "Fetching GPG key: ${url}"
  curl -fsSL "${url}" \
    | gpg --dearmor \
    | install -m 0644 /dev/stdin "${dest}"
}

# ── Debian/Ubuntu upstream repo setup ────────────────────────────────────────
# alvistack is the recommended replacement for the discontinued Kubic repo.
# It provides up-to-date Podman packages for Ubuntu LTS and Debian stable.
# Repo: https://software.opensuse.org/download/package?package=podman&project=home:alvistack
setup_upstream_repo_debian() {
  local ver="${DISTRO_VERSION_ID}"
  local major="${ver%%.*}"

  # Ubuntu 24.04+ and Debian 12+ ship Podman 5.x natively — no extra repo needed
  if [[ "${DISTRO_ID}" == "ubuntu" && "${major}" -ge 24 ]]; then
    log "Ubuntu ${ver}: official repos include Podman 5.x — no upstream repo needed."
    return 0
  fi
  if [[ "${DISTRO_ID}" == "debian" && "${major}" -ge 12 ]]; then
    log "Debian ${ver}: official repos include Podman 5.x — no upstream repo needed."
    return 0
  fi

  # Older Ubuntu/Debian: add alvistack OBS repo for latest Podman
  log "Ubuntu/Debian ${ver}: adding alvistack upstream repo for Podman 5.x..."

  local codename
  codename="$(lsb_release -cs 2>/dev/null || echo "${VERSION_CODENAME:-}")"
  [[ -n "${codename}" ]] \
    || die "Could not determine distro codename. Install lsb-release and retry."

  local keyring="/etc/apt/keyrings/home_alvistack.gpg"
  local sources="/etc/apt/sources.list.d/home_alvistack.list"

  install -d -m 0755 /etc/apt/keyrings

  add_apt_gpg_key \
    "https://download.opensuse.org/repositories/home:alvistack/xUbuntu_$(echo "${ver}" | cut -d. -f1-2)/Release.key" \
    "${keyring}"

  printf 'deb [signed-by=%s] https://download.opensuse.org/repositories/home:alvistack/xUbuntu_%s/ /\n' \
    "${keyring}" "$(echo "${ver}" | cut -d. -f1-2)" \
    > "${sources}"

  chmod 0644 "${sources}"
  ok "alvistack upstream repo added (${sources})."
}

# ── RHEL/Fedora upstream repo setup ──────────────────────────────────────────
# Fedora 38+ and RHEL/CentOS Stream 9+ already carry Podman 5.x.
# For older RHEL (8.x), EPEL is the safest production path.
# The Copr rhcontainerbot/podman-next repo carries cutting-edge builds
# but is explicitly marked NOT FOR PRODUCTION by the Podman team.
setup_upstream_repo_rhel() {
  local ver="${DISTRO_VERSION_ID}"
  local major="${ver%%.*}"

  # Fedora always has latest
  if [[ "${DISTRO_ID}" == "fedora" ]]; then
    log "Fedora ${ver}: official repos include the latest Podman — no upstream repo needed."
    return 0
  fi

  # RHEL/CentOS Stream 9+ has Podman 5.x in AppStream
  if [[ "${major}" -ge 9 ]]; then
    log "RHEL/CentOS ${ver}: AppStream includes Podman 5.x — no upstream repo needed."
    return 0
  fi

  # RHEL/CentOS 8.x: add EPEL for a more recent Podman
  if [[ "${major}" -eq 8 ]]; then
    warn "RHEL/CentOS ${ver}: official repos may have Podman 4.x. Adding EPEL for a newer build."
    warn "Note: the Podman team's Copr 'podman-next' repo has the very latest builds"
    warn "but is explicitly NOT recommended for production. EPEL is the safer choice."
    local pkg_mgr; command -v dnf &>/dev/null && pkg_mgr=dnf || pkg_mgr=yum
    if ! "${pkg_mgr}" repolist | grep -qi epel; then
      "${pkg_mgr}" install -y \
        "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${major}.noarch.rpm" \
        || warn "Could not add EPEL — proceeding with distro repo packages."
    else
      log "EPEL already enabled."
    fi
    return 0
  fi

  warn "RHEL/CentOS ${ver} is very old. Package availability is limited."
  warn "Consider upgrading to RHEL/CentOS Stream 9 or newer."
}

# ── openSUSE upstream repo setup ─────────────────────────────────────────────
# Tumbleweed is rolling and always has the latest. Leap needs the devel repo.
setup_upstream_repo_suse() {
  if [[ "${DISTRO_ID}" == "opensuse-tumbleweed" ]]; then
    log "openSUSE Tumbleweed: rolling release, always has latest Podman."
    return 0
  fi

  log "openSUSE Leap ${DISTRO_VERSION_ID}: adding devel:kubic:libcontainers:stable repo..."
  zypper addrepo --refresh --check \
    "https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable/openSUSE_Leap_${DISTRO_VERSION_ID}/devel:kubic:libcontainers:stable.repo" \
    2>/dev/null || log "Repo already exists, skipping."
  zypper --gpg-auto-import-keys refresh
  ok "openSUSE upstream repo ready."
}

# ── Dispatch repo setup by family ────────────────────────────────────────────
setup_upstream_repos() {
  log "Checking if an upstream repo is needed for the latest Podman..."
  case "${FAMILY}" in
    debian) setup_upstream_repo_debian ;;
    rhel)   setup_upstream_repo_rhel   ;;
    suse)   setup_upstream_repo_suse   ;;
    arch)   log "Arch Linux: always ships latest upstream Podman." ;;
    alpine) log "Alpine: community repo ships latest Podman." ;;
    *)      warn "Unknown distro family — skipping upstream repo setup." ;;
  esac
}

# =============================================================================
# PACKAGE INSTALLATION
# =============================================================================
# Key packages:
#   podman           — the container engine
#   podman-docker    — provides 'docker' as an alias of 'podman' (where available)
#   netavark/slirp4netns — userspace networking for rootless containers
#                          (netavark is the modern default in Podman 5.x;
#                           slirp4netns kept as fallback for older setups)
#   fuse-overlayfs   — layered storage driver in rootless mode
#   uidmap/shadow    — newuidmap/newgidmap tools for UID mapping
#   dbus-user-session — required for systemctl --user
install_packages() {
  log "Installing Podman and dependencies (family: ${FAMILY})..."
  case "${FAMILY}" in
    debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y -qq

      # Build package list dynamically — podman-docker is not in all repos
      local pkgs=(podman slirp4netns fuse-overlayfs uidmap dbus-user-session ca-certificates)
      if apt-cache show podman-docker &>/dev/null 2>&1; then
        pkgs+=(podman-docker)
      else
        warn "podman-docker not in repo — a docker wrapper will be created manually."
      fi
      apt-get install -y --no-install-recommends "${pkgs[@]}"
      ;;

    rhel)
      local pkg_mgr; command -v dnf &>/dev/null && pkg_mgr=dnf || pkg_mgr=yum
      local pkgs=(podman slirp4netns fuse-overlayfs shadow-utils)
      if "${pkg_mgr}" info podman-docker &>/dev/null 2>&1; then
        pkgs+=(podman-docker)
      else
        warn "podman-docker not in repo — a docker wrapper will be created manually."
      fi
      "${pkg_mgr}" install -y "${pkgs[@]}"
      ;;

    suse)
      local pkgs=(podman slirp4netns fuse-overlayfs shadow)
      if zypper search -x podman-docker &>/dev/null 2>&1; then
        pkgs+=(podman-docker)
      fi
      zypper --non-interactive install -y "${pkgs[@]}"
      ;;

    arch)
      pacman -Sy --noconfirm podman slirp4netns fuse-overlayfs shadow
      warn "podman-docker is AUR-only on Arch — a docker wrapper will be created manually."
      ;;

    alpine)
      apk add --no-cache podman slirp4netns fuse-overlayfs shadow-uidmap
      ;;

    *)
      die "Distribution family not supported automatically.
           Install manually: podman slirp4netns fuse-overlayfs uidmap
           Then re-run this script."
      ;;
  esac
  ok "Packages installed."
}

# =============================================================================
# VERSION VERIFICATION
# =============================================================================
# Confirms that the installed Podman meets the minimum major version.
# If the distro repo installed an old version despite our repo setup attempt,
# the script aborts with actionable guidance rather than silently proceeding
# with a version that may lack full rootless support.
check_podman_version() {
  local version_str major minor

  command -v podman &>/dev/null \
    || die "Podman not found in PATH after installation."

  version_str="$(podman --version 2>/dev/null | awk '{print $3}')"
  major="${version_str%%.*}"
  log "Podman version installed: ${version_str}"

  if [[ -z "${major}" || ! "${major}" =~ ^[0-9]+$ ]]; then
    die "Could not parse Podman version string: '${version_str}'"
  fi

  if [[ "${major}" -lt "${PODMAN_MIN_MAJOR}" ]]; then
    die "Podman ${version_str} is below the minimum required version (${PODMAN_MIN_MAJOR}.x).
         The distro repo may have overridden the upstream repo.
         Options:
           1) On Ubuntu 22.04: install via Homebrew — brew install podman
           2) On RHEL 8:       check EPEL availability or upgrade the OS
           3) Manual install:  https://github.com/containers/podman/releases"
  fi

  ok "Version check passed: ${version_str} (>= ${PODMAN_MIN_MAJOR}.0)."
}

# =============================================================================
# ROOTLESS CONFIGURATION
# =============================================================================

# ── UID/GID subordinate mapping ──────────────────────────────────────────────
# In rootless mode, 'root' inside a container maps to an unprivileged UID range
# outside. usermod handles range allocation safely; we do NOT calculate ranges
# manually to avoid integer overflow with high UIDs.
configure_subids() {
  local user="$1"

  if grep -q "^${user}:" /etc/subuid 2>/dev/null; then
    log "User '${user}' already has a subuid entry — kept as is."
  else
    log "Allocating subuid range for '${user}'..."
    usermod --add-subuids 100000-165535 "${user}" \
      || die "Failed to set subuid for '${user}'."
  fi

  if grep -q "^${user}:" /etc/subgid 2>/dev/null; then
    log "User '${user}' already has a subgid entry — kept as is."
  else
    log "Allocating subgid range for '${user}'..."
    usermod --add-subgids 100000-165535 "${user}" \
      || die "Failed to set subgid for '${user}'."
  fi

  ok "UID/GID subordinate mapping configured."
}

# ── Lingering ────────────────────────────────────────────────────────────────
# Allows user services (Podman socket) to remain active without an open session.
enable_linger() {
  local user="$1"
  log "Enabling systemd lingering for '${user}'..."
  loginctl enable-linger "${user}" \
    || die "Failed to enable lingering for '${user}'."
  ok "Lingering enabled."
}

# ── Podman user socket (Docker-compatible API) ────────────────────────────────
# Failure is WARN, not fatal: the socket can be enabled after the next login.
# SOCKET_ENABLED is set to reflect the real outcome in the summary.
enable_user_socket() {
  log "Activating the Podman user socket (Docker-compatible API)..."

  # Wait up to 8 s for /run/user/<uid> to appear after loginctl enable-linger
  local retries=8
  while (( retries-- > 0 )); do
    [[ -d "/run/user/${TARGET_UID}" ]] && break
    sleep 1
  done

  if [[ ! -d "/run/user/${TARGET_UID}" ]]; then
    warn "/run/user/${TARGET_UID} is not yet available (non-fatal)."
    warn "Enable the socket manually after your next login as '${TARGET_USER}':"
    warn "  systemctl --user enable --now podman.socket"
    return 0
  fi

  if run_as_user systemctl --user enable --now podman.socket 2>/dev/null; then
    SOCKET_ENABLED=true
    ok "User socket active."
  else
    warn "Could not enable podman.socket automatically (non-fatal)."
    warn "Enable manually as '${TARGET_USER}':"
    warn "  systemctl --user enable --now podman.socket"
  fi
}

# =============================================================================
# DOCKER COMPATIBILITY
# =============================================================================
# 1) If podman-docker was installed, the 'docker' binary is already present.
# 2) Otherwise, a POSIX sh wrapper is created at /usr/local/bin/docker.
# 3) A POSIX-safe /etc/profile.d snippet exports DOCKER_HOST for every user,
#    pointing each one to their own rootless Podman socket.
#    (Written in sh, not bash — /etc/profile.d/ is sourced by /bin/sh.)
configure_docker_compat() {
  log "Configuring Docker compatibility..."

  if ! command -v docker &>/dev/null; then
    log "Creating docker → podman wrapper at /usr/local/bin/docker..."
    cat > /usr/local/bin/docker <<'EOF'
#!/bin/sh
# Generated by podman-install.sh — delegates 'docker' to 'podman'
exec podman "$@"
EOF
    chmod 0755 /usr/local/bin/docker
    ok "docker wrapper created."
  else
    ok "docker command already present (via podman-docker)."
  fi

  # POSIX sh snippet — no bashisms, safe for /bin/sh sourcing
  local profile=/etc/profile.d/podman-docker.sh
  cat > "${profile}" <<'EOF'
# Generated by podman-install.sh
# Points DOCKER_HOST to the current user's rootless Podman socket.
# Written in POSIX sh — safe to source from /bin/sh.
_uid=$(id -u)
_podman_sock="/run/user/${_uid}/podman/podman.sock"
if [ -z "${DOCKER_HOST:-}" ] && [ -S "${_podman_sock}" ]; then
  export DOCKER_HOST="unix://${_podman_sock}"
fi
unset _uid _podman_sock
EOF
  chmod 0644 "${profile}"
  ok "DOCKER_HOST configured in ${profile}."
}

# =============================================================================
# VERIFICATION
# =============================================================================
verify() {
  log "Verifying installation..."

  command -v podman &>/dev/null \
    || die "Podman is not available in PATH after installation."

  log "Podman version: $(podman --version)"

  local rootless
  rootless="$(run_as_user podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null \
              || echo "unknown")"

  if [[ "${rootless}" == "true" ]]; then
    ok "Podman confirmed running in ROOTLESS mode for '${TARGET_USER}'."
  else
    warn "Could not confirm rootless mode automatically (got: '${rootless}')."
    warn "Verify as '${TARGET_USER}' with:  podman info | grep -i rootless"
  fi
}

# =============================================================================
# REVERT / UNINSTALL
# =============================================================================
revert() {
  log "Reverting Podman installation for user '${TARGET_USER}'..."

  # Disable user socket if /run/user/<uid> exists
  if [[ -d "/run/user/${TARGET_UID}" ]]; then
    run_as_user systemctl --user disable --now podman.socket 2>/dev/null || true
    ok "User socket disabled."
  fi

  loginctl disable-linger "${TARGET_USER}" 2>/dev/null || true
  ok "Lingering disabled."

  rm -f /etc/profile.d/podman-docker.sh
  if [[ -f /usr/local/bin/docker ]] \
      && grep -q 'exec podman' /usr/local/bin/docker 2>/dev/null; then
    rm -f /usr/local/bin/docker
  fi
  ok "Profile snippet and docker wrapper removed."

  # Remove upstream repo files if they were added
  rm -f /etc/apt/sources.list.d/home_alvistack.list \
        /etc/apt/keyrings/home_alvistack.gpg 2>/dev/null || true

  log "Removing Podman packages (best-effort)..."
  case "${FAMILY}" in
    debian)
      apt-get remove -y podman podman-docker slirp4netns fuse-overlayfs \
        uidmap dbus-user-session 2>/dev/null || true ;;
    rhel)
      local pkg_mgr; command -v dnf &>/dev/null && pkg_mgr=dnf || pkg_mgr=yum
      "${pkg_mgr}" remove -y podman podman-docker slirp4netns \
        fuse-overlayfs shadow-utils 2>/dev/null || true ;;
    suse)
      zypper --non-interactive remove -y podman podman-docker \
        slirp4netns fuse-overlayfs 2>/dev/null || true ;;
    arch)
      pacman -Rns --noconfirm podman slirp4netns fuse-overlayfs 2>/dev/null || true ;;
    alpine)
      apk del podman slirp4netns fuse-overlayfs shadow-uidmap 2>/dev/null || true ;;
  esac
  ok "Packages removed."

  logger -t "${LOG_TAG}" \
    "reverted for user '${TARGET_USER}' by '$(logname 2>/dev/null || echo unknown)'"
  log "Revert complete. /etc/subuid and /etc/subgid entries were left intact (harmless)."
}

# =============================================================================
# SUMMARY
# =============================================================================
summary() {
  local socket_status="not active — run: systemctl --user enable --now podman.socket"
  [[ "${SOCKET_ENABLED}" == true ]] && socket_status="active"

  cat <<EOF

${C_OK}========================================================${C_RESET}
${C_OK} Installation complete  (v${SCRIPT_VERSION})${C_RESET}
${C_OK}========================================================${C_RESET}

  Engine     : Podman $(podman --version | awk '{print $3}') (rootless)
  User       : ${TARGET_USER}
  docker cmd : available (wrapper → podman)
  Socket     : ${socket_status}
  DOCKER_HOST: set via /etc/profile.d/podman-docker.sh

  Next steps (as user ${TARGET_USER}):
    1) Open a new shell or run:  source /etc/profile.d/podman-docker.sh
    2) podman run --rm hello-world
    3) docker run --rm hello-world   (same result via Podman)

  To undo this installation:
    sudo bash ${SCRIPT_NAME} --revert

  Security note:
    Podman runs WITHOUT elevated privileges. Do not use root mode
    unless there is a concrete, justified reason.

EOF
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  log "Starting podman-install.sh v${SCRIPT_VERSION}"
  logger -t "${LOG_TAG}" \
    "started by '$(logname 2>/dev/null || echo unknown)' for user '${TARGET_USER}'"

  if [[ "${REVERT}" == true ]]; then
    revert
    exit 0
  fi

  setup_upstream_repos    # add distro-specific upstream repos when needed
  install_packages        # install Podman and dependencies
  check_podman_version    # abort if installed version is below PODMAN_MIN_MAJOR
  configure_subids "${TARGET_USER}"
  enable_linger "${TARGET_USER}"
  enable_user_socket
  configure_docker_compat
  verify
  summary

  logger -t "${LOG_TAG}" \
    "completed successfully for user '${TARGET_USER}'"
}

main "$@"
