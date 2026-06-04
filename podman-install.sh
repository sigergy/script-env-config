#!/usr/bin/env bash
#
# install-podman.sh
# ---------------------------------------------------------------------------
# Instala y configura Podman en modo ROOTLESS (sin privilegios) en un entorno
# de producción Linux, con compatibilidad de comandos Docker.
#
# Filosofía de seguridad:
#   - Se necesita 'sudo' SOLO para instalar paquetes y preparar el sistema.
#   - Podman se deja corriendo SIN privilegios elevados (rootless), que es la
#     forma más segura y la principal ventaja frente a Docker.
#
# Uso recomendado (revisa el script ANTES de ejecutarlo):
#   curl -fsSL https://raw.githubusercontent.com/USUARIO/REPO/main/install-podman.sh -o install-podman.sh
#   less install-podman.sh        # <-- inspecciona qué hace
#   sudo bash install-podman.sh
#
# Uso rápido (cómodo pero confías ciegamente en el contenido remoto):
#   curl -fsSL https://raw.githubusercontent.com/USUARIO/REPO/main/install-podman.sh | sudo bash
#
# Variables opcionales:
#   PODMAN_USER=nombre   -> usuario para el que se configura rootless
#                           (por defecto: el usuario que invocó sudo)
# ---------------------------------------------------------------------------

set -euo pipefail

# --------------------------- Utilidades de salida --------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_INFO=$'\033[1;34m'; C_OK=$'\033[1;32m'
  C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'
else
  C_RESET=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""
fi
log()  { printf '%s[INFO]%s %s\n'  "$C_INFO" "$C_RESET" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n'  "$C_OK"   "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n'  "$C_WARN" "$C_RESET" "$*" >&2; }
err()  { printf '%s[ERR ]%s %s\n'  "$C_ERR"  "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

# --------------------------- Comprobación de root --------------------------
if [[ "${EUID}" -ne 0 ]]; then
  err "This script needs root privileges to INSTALL packages."
  err "Run it again like this:  sudo bash $0"
  exit 1
fi

# ------------------- Determinar el usuario rootless ------------------------
# Rootless debe configurarse para un usuario NORMAL, nunca para root.
TARGET_USER="${PODMAN_USER:-${SUDO_USER:-}}"

if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == "root" ]]; then
  die "No non-root user detected.
       Run with sudo from your normal user, or pass PODMAN_USER:
         sudo PODMAN_USER=myuser bash $0"
fi

if ! id "${TARGET_USER}" &>/dev/null; then
  die "User '${TARGET_USER}' does not exist."
fi

TARGET_UID="$(id -u "${TARGET_USER}")"
log "User for rootless Podman: ${TARGET_USER} (uid ${TARGET_UID})"

# Ejecuta un comando como el usuario objetivo con su sesión de usuario válida
# (necesario para que funcionen 'systemctl --user' y el socket de usuario).
run_as_user() {
  sudo -u "${TARGET_USER}" \
    XDG_RUNTIME_DIR="/run/user/${TARGET_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" \
    "$@"
}

# --------------------------- Detección de distro ---------------------------
if [[ ! -r /etc/os-release ]]; then
  die "/etc/os-release not found; unsupported distribution."
fi
# shellcheck disable=SC1091
. /etc/os-release
DISTRO_ID="${ID:-}"
DISTRO_LIKE="${ID_LIKE:-}"
log "Detected distribution: ${PRETTY_NAME:-$DISTRO_ID}"

pkg_family() {
  case " ${DISTRO_ID} ${DISTRO_LIKE} " in
    *" debian "*|*" ubuntu "*) echo "debian" ;;
    *" rhel "*|*" fedora "*|*" centos "*) echo "rhel" ;;
    *" suse "*|*" opensuse "*)  echo "suse" ;;
    *" arch "*)                 echo "arch" ;;
    *) echo "unknown" ;;
  esac
}
FAMILY="$(pkg_family)"

# --------------------------- Instalación de paquetes -----------------------
# Paquetes clave:
#   podman           -> el motor de contenedores
#   podman-docker    -> provee el comando 'docker' como alias de 'podman'
#   slirp4netns      -> red en modo rootless
#   fuse-overlayfs   -> almacenamiento en capas en modo rootless
#   uidmap/shadow    -> herramientas newuidmap/newgidmap para el mapeo de UIDs
#   dbus-user-session-> sesión de usuario para systemctl --user
install_packages() {
  log "Installing Podman and dependencies (family: ${FAMILY})..."
  case "${FAMILY}" in
    debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y --no-install-recommends \
        podman podman-docker slirp4netns fuse-overlayfs uidmap \
        dbus-user-session ca-certificates
      ;;
    rhel)
      if command -v dnf &>/dev/null; then PKG=dnf; else PKG=yum; fi
      "${PKG}" install -y \
        podman podman-docker slirp4netns fuse-overlayfs shadow-utils
      ;;
    suse)
      zypper --non-interactive install -y \
        podman podman-docker slirp4netns fuse-overlayfs shadow
      ;;
    arch)
      pacman -Sy --noconfirm \
        podman podman-docker slirp4netns fuse-overlayfs shadow
      ;;
    *)
      die "Distribution family not supported automatically.
           Install manually: podman podman-docker slirp4netns fuse-overlayfs uidmap"
      ;;
  esac
  ok "Packages installed."
}

# --------------------- Permisos: mapeo de UIDs/GIDs ------------------------
# En rootless, el 'root' de dentro del contenedor se mapea a un rango de UIDs
# sin privilegios fuera. Esto es lo que hace seguro a Podman: NO se dan
# permisos elevados al motor, solo un rango de subordinados al usuario.
configure_subids() {
  local user="$1"
  local range_size=65536
  local start=100000

  # Reserva un rango no solapado por usuario (start + uid*range_size).
  local uid; uid="$(id -u "${user}")"
  local sub_start=$(( start + uid * range_size ))
  local sub_end=$(( sub_start + range_size - 1 ))

  if grep -q "^${user}:" /etc/subuid; then
    log "User '${user}' already has an entry in /etc/subuid (kept as is)."
  else
    log "Assigning subuid ${sub_start}-${sub_end} to ${user}..."
    usermod --add-subuids "${sub_start}-${sub_end}" "${user}"
  fi

  if grep -q "^${user}:" /etc/subgid; then
    log "User '${user}' already has an entry in /etc/subgid (kept as is)."
  else
    log "Assigning subgid ${sub_start}-${sub_end} to ${user}..."
    usermod --add-subgids "${sub_start}-${sub_end}" "${user}"
  fi
  ok "UID/GID mapping configured."
}

# ------------------- Lingering: servicios sin login -----------------------
# Permite que el socket de usuario de Podman siga activo aunque el usuario no
# tenga sesión abierta (imprescindible en servidores de producción).
enable_linger() {
  local user="$1"
  log "Enabling lingering for '${user}'..."
  loginctl enable-linger "${user}"
  ok "Lingering enabled."
}

# ----------------- Socket de usuario (API Docker-compatible) ---------------
# El socket de Podman expone una API compatible con Docker. Apuntando
# DOCKER_HOST a este socket, herramientas que hablan con Docker funcionan
# contra Podman rootless, sin demonio privilegiado.
enable_user_socket() {
  log "Enabling the Podman user socket (Docker-compatible API)..."
  # Pequeña espera por si /run/user/<uid> aún no está listo tras enable-linger.
  for _ in 1 2 3 4 5; do
    [[ -d "/run/user/${TARGET_UID}" ]] && break
    sleep 1
  done
  if [[ ! -d "/run/user/${TARGET_UID}" ]]; then
    warn "/run/user/${TARGET_UID} does not exist. The socket will be enabled"
    warn "after the user's next login. Manual command:"
    warn "  systemctl --user enable --now podman.socket"
    return 0
  fi
  run_as_user systemctl --user enable --now podman.socket || {
    warn "Could not enable podman.socket automatically."
    warn "Enable it manually as '${TARGET_USER}':"
    warn "  systemctl --user enable --now podman.socket"
    return 0
  }
  ok "User socket active."
}

# --------------------- Compatibilidad con Docker ---------------------------
# 1) podman-docker ya instala el comando 'docker'.
# 2) Exportamos DOCKER_HOST para todos los usuarios apuntando a su socket
#    de usuario de Podman (cada uno al suyo, gracias a $(id -u)).
configure_docker_compat() {
  log "Configuring Docker compatibility..."
  local profile=/etc/profile.d/podman-docker.sh
  cat > "${profile}" <<'EOF'
# Generated by install-podman.sh
# Points DOCKER_HOST to the current user's rootless Podman socket.
if [ -z "${DOCKER_HOST:-}" ] && [ -n "${UID:-$(id -u)}" ]; then
  _podman_sock="/run/user/$(id -u)/podman/podman.sock"
  if [ -S "${_podman_sock}" ]; then
    export DOCKER_HOST="unix://${_podman_sock}"
  fi
  unset _podman_sock
fi
EOF
  chmod 0644 "${profile}"
  ok "Docker compatibility configured (DOCKER_HOST in ${profile})."
}

# ----------------------------- Verificación --------------------------------
verify() {
  log "Verifying installation..."
  if ! command -v podman &>/dev/null; then
    die "Podman did not become available in PATH."
  fi
  log "Podman version: $(podman --version)"
  log "Rootless test (as ${TARGET_USER}):"
  if run_as_user podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null \
       | grep -qi true; then
    ok "Podman is running in ROOTLESS mode for ${TARGET_USER}."
  else
    warn "Could not confirm rootless mode automatically."
    warn "Verify as '${TARGET_USER}' with: podman info | grep rootless"
  fi
}

# ------------------------------- Resumen -----------------------------------
summary() {
  cat <<EOF

${C_OK}========================================================${C_RESET}
${C_OK} Installation complete${C_RESET}
${C_OK}========================================================${C_RESET}

  Engine installed : Podman (rootless)
  User             : ${TARGET_USER}
  docker command   : available (alias of podman via podman-docker)
  DOCKER_HOST      : /etc/profile.d/podman-docker.sh

  Next steps (as user ${TARGET_USER}):
    1) Open a new session or run:  source /etc/profile.d/podman-docker.sh
    2) Test:   podman run --rm hello-world
    3) Test:   docker run --rm hello-world   (same result via Podman)

  Security note:
    Podman runs WITHOUT elevated privileges. Do not run it as root unless
    there is a concrete, justified need.

EOF
}

# ------------------------------- Main --------------------------------------
main() {
  install_packages
  configure_subids "${TARGET_USER}"
  enable_linger "${TARGET_USER}"
  enable_user_socket
  configure_docker_compat
  verify
  summary
}

main "$@"
