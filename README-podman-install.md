# podman-install.sh

Bash script for Linux that installs and configures Podman in **rootless mode** with full Docker command compatibility. It automatically ensures you get the latest stable version of Podman (version `5.x` or higher) by setting up verified upstream repositories on supported distributions where official packages lag behind.

---

## What it does

1. **Upstream Repositories**: Registers official upstream repositories (like `alvistack` for older Debian/Ubuntu, or Kubic stable for openSUSE Leap) using strict GPG fingerprint verification to ensure packages are secure and up-to-date.
2. **Package Installation**: Installs `podman`, userspace networking (`slirp4netns`/`netavark`), layered storage driver (`fuse-overlayfs`), subordinate UID/GID mappings tools (`uidmap`/`shadow`), and session management (`dbus-user-session`).
3. **Version Check**: Audits the installed Podman binary and aborts if it is below the required minimum version (`5.0.0`).
4. **Rootless Configuration**: 
   - Dynamically allocates a subordinate UID/GID mapping range (`100000-165535`) via `usermod`.
   - Enables systemd linger (`loginctl enable-linger`) so containers run in the background after the user logs out.
   - Activates the `podman.socket` user-level service to expose a Docker-compatible API.
5. **Docker CLI Compatibility**:
   - Generates a lightweight `/usr/local/bin/docker` wrapper that delegates commands directly to `podman` (if the official `podman-docker` wrapper package is not available).
   - Writes a POSIX-compliant script to `/etc/profile.d/podman-docker.sh` to automatically export `DOCKER_HOST` pointing to each user's individual rootless socket.

---

## Requirements

- **Shell**: `bash >= 4`
- **Privileges**: Root execution via `sudo` is required to install packages and adjust system configuration. However, **Podman runs entirely in rootless user space**.
- **Supported Distributions**:
  - **Debian / Ubuntu** (LTS versions like 20.04, 22.04, 24.04)
  - **RHEL / Fedora / CentOS**
  - **openSUSE** (Leap and Tumbleweed)
  - **Arch Linux**
  - **Alpine Linux**

---

## Usage

### Recommended flow (download → verify → inspect → run)

```bash
# 1. Download the script
curl -fsSL https://raw.githubusercontent.com/USER/REPO/COMMIT/podman-install.sh \
     -o /tmp/podman-install.sh

# 2. Verify integrity
echo "EXPECTED_SHA256  /tmp/podman-install.sh" | sha256sum --check --strict -

# 3. Inspect the code before running
less /tmp/podman-install.sh

# 4. Run installer (defaults to configuring the invoking SUDO_USER)
sudo bash /tmp/podman-install.sh
```

> ⚠️ Never pipe remote scripts directly into bash (`curl ... | sudo bash`) in production environments without performing an integrity and safety check.

### Options

| Flag | Description |
|---|---|
| `--user=<username>` | Target system user to configure rootless Podman for (default: `$SUDO_USER`). |
| `--revert` | Uninstall Podman packages, disable user lingers/sockets, and remove helper wrappers. |
| `--help`, `-h` | Show usage instructions. |

### Environment Variables

| Variable | Description |
|---|---|
| `PODMAN_USER` | Alternative way to specify the target user (equivalent to `--user`). |

---

## What happens internally, step-by-step

1. **Preflight**: Checks that the script is running as root and that essential tools (`curl`, `gpg`, `logger`) are installed.
2. **User Resolution**: Resolves the target user (prioritizes `--user`, then `PODMAN_USER`, then `$SUDO_USER`). Validates that the user exists and is not `root`.
3. **Distro Detection**: Detects the Linux distribution family from `/etc/os-release`.
4. **Upstream Repositories**:
   - For Debian/Ubuntu < 24.04: Registers the `alvistack` OBS repo and verifies its GPG fingerprint against `9FB7EF551E7453D9A98CCCCF6B7C63E378DB6F2B`.
   - For openSUSE Leap: Registers the `devel:kubic:libcontainers:stable` OBS repo.
   - For CentOS/RHEL 8: Enables the EPEL repository.
5. **Package Installation**: Installs distribution-specific packages.
6. **Version Verification**: Runs `podman --version` and asserts that the major version is `>= 5`.
7. **Subordinate UID/GID Mapping**: Adds subordinate UID/GID mappings for the target user in `/etc/subuid` and `/etc/subgid` (range `100000-165535`).
8. **Lingering & Socket Activation**: Enables user linger with `loginctl`, then runs `systemctl --user enable --now podman.socket` as the target user.
9. **Docker Compatibility**: Creates the `/usr/local/bin/docker` command wrapper and the `/etc/profile.d/podman-docker.sh` environment exporter.
10. **Verification**: Checks that Podman reports running in `rootless` mode for the user.

---

## Files Created / Modified

| Path | Permissions | Description |
|---|---|---|
| `/etc/apt/sources.list.d/home_alvistack.list` | `0644` | Debian/Ubuntu upstream repository sources list (if applicable). |
| `/etc/apt/keyrings/home_alvistack.gpg` | `0644` | Verified alvistack GPG key (if applicable). |
| `/usr/local/bin/docker` | `0755` | Executable wrapper delegating Docker commands to Podman. |
| `/etc/profile.d/podman-docker.sh` | `0644` | POSIX sh script setting up `DOCKER_HOST` dynamically. |

---

## Revert / Uninstall

To remove Podman, disable lingers, and clean up the environment, run:

```bash
sudo bash podman-install.sh --revert
```

*Note: For safety and system stability, subordinate UID/GID entries in `/etc/subuid` and `/etc/subgid` are left intact upon reversion.*

---

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Error (details logged to console and system syslog) |

---

## Version

`1.3.0`
