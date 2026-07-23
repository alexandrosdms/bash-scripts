#!/usr/bin/env bash
# =============================================================================
# audit_packages.sh
# =============================================================================
# Audits currently installed packages on a Debian/Ubuntu system and checks
# their availability (and name equivalents) on a target distro — either
# another Ubuntu/Debian release or Fedora/RHEL.
#
# Produces:
#   audit_report_<ts>.txt          Human-readable full report
#   packages_to_install_<ts>.txt   Direct input for install_packages.sh
#   packages_unavailable_<ts>.txt  Packages needing manual handling
#
# Usage:
#   ./audit_packages.sh [TARGET] [OUTPUT_DIR]
#
# TARGET can be:
#   Ubuntu codename : focal | jammy | noble | oracular   (default: noble)
#   Fedora target   : fedora40 | fedora41 | fedora42 | rhel9 | rhel10
#
# Examples:
#   ./audit_packages.sh noble             # Ubuntu → Ubuntu 24.04
#   ./audit_packages.sh fedora42          # Ubuntu → Fedora 42
#   ./audit_packages.sh rhel9 ./out       # Ubuntu → RHEL 9, custom output dir
#
# Requirements (source host): dpkg or apt-mark, curl or wget
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
TARGET="${1:-noble}"
OUTPUT_DIR="${2:-.}"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
REPORT_FILE="${OUTPUT_DIR}/audit_report_${TIMESTAMP}.txt"
INSTALL_LIST="${OUTPUT_DIR}/packages_to_install_${TIMESTAMP}.txt"
UNAVAILABLE_LIST="${OUTPUT_DIR}/packages_unavailable_${TIMESTAMP}.txt"
TMP_DIR=$(mktemp -d)

# ---------------------------------------------------------------------------
# Colour codes
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; RESET=''
fi

log()  { echo -e "${BLUE}[INFO]${RESET}  $*"; }
ok()   { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
info() { echo -e "${CYAN}[NOTE]${RESET}  $*"; }

cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# HTTP helper
# ---------------------------------------------------------------------------
if command -v curl &>/dev/null; then
    HTTP_GET() { curl -fsSL --max-time 15 "$1" 2>/dev/null; }
elif command -v wget &>/dev/null; then
    HTTP_GET() { wget -qO- --timeout=15 "$1" 2>/dev/null; }
else
    err "Neither 'curl' nor 'wget' found. Cannot query package APIs."
    exit 1
fi

# ---------------------------------------------------------------------------
# Determine target distro family
# ---------------------------------------------------------------------------
TARGET_FAMILY=""      # "ubuntu" | "fedora" | "rhel"
TARGET_VERSION=""     # e.g. "noble", "42", "9"

case "${TARGET}" in
    focal|jammy|lunar|mantic|noble|oracular)
        TARGET_FAMILY="ubuntu"; TARGET_VERSION="${TARGET}" ;;
    fedora[0-9]*)
        TARGET_FAMILY="fedora"; TARGET_VERSION="${TARGET#fedora}" ;;
    rhel[0-9]*|centos[0-9]*)
        TARGET_FAMILY="rhel";   TARGET_VERSION="${TARGET//[^0-9]/}" ;;
    *)
        err "Unknown target '${TARGET}'."
        err "Supported: focal jammy noble oracular  |  fedora40 fedora41 fedora42  |  rhel9 rhel10"
        exit 1 ;;
esac

log "Target distro family : ${TARGET_FAMILY} ${TARGET_VERSION}"

# ---------------------------------------------------------------------------
# Debian → Fedora/RHEL package name translation table
# Format: deb_name:rpm_name  (same name entries omitted — handled dynamically)
# ---------------------------------------------------------------------------
declare -A DEB_TO_RPM=(
    # Build tools
    ["build-essential"]="gcc gcc-c++ make"
    ["gcc"]="gcc"
    ["g++"]="gcc-c++"
    ["libc6-dev"]="glibc-devel"
    ["libstdc++-dev"]="libstdc++-devel"
    ["cmake"]="cmake"
    ["pkg-config"]="pkgconf"
    ["autoconf"]="autoconf"
    ["automake"]="automake"
    ["libtool"]="libtool"
    ["ninja-build"]="ninja-build"
    ["meson"]="meson"

    # Java / JVM
    ["default-jdk"]="java-latest-openjdk-devel"
    ["default-jre"]="java-latest-openjdk"
    ["openjdk-17-jdk"]="java-17-openjdk-devel"
    ["openjdk-17-jre"]="java-17-openjdk"
    ["openjdk-21-jdk"]="java-21-openjdk-devel"
    ["openjdk-21-jre"]="java-21-openjdk"
    ["maven"]="maven"
    ["gradle"]="gradle"

    # Python
    ["python3"]="python3"
    ["python3-pip"]="python3-pip"
    ["python3-dev"]="python3-devel"
    ["python3-venv"]="python3"        # venv is built-in on Fedora
    ["python3-setuptools"]="python3-setuptools"
    ["python-is-python3"]="python-unversioned-command"

    # Networking
    ["net-tools"]="net-tools"
    ["iproute2"]="iproute"
    ["iputils-ping"]="iputils"
    ["dnsutils"]="bind-utils"
    ["nmap"]="nmap"
    ["curl"]="curl"
    ["wget"]="wget"
    ["openssh-client"]="openssh-clients"
    ["openssh-server"]="openssh-server"
    ["openvpn"]="openvpn"
    ["wireguard"]="wireguard-tools"
    ["iptables"]="iptables"
    ["ufw"]="ufw"
    ["firewalld"]="firewalld"
    ["network-manager"]="NetworkManager"
    ["libnm-dev"]="NetworkManager-devel"

    # Compression
    ["zip"]="zip"
    ["unzip"]="unzip"
    ["p7zip-full"]="p7zip p7zip-plugins"
    ["bzip2"]="bzip2"
    ["xz-utils"]="xz"
    ["zstd"]="zstd"
    ["gzip"]="gzip"
    ["tar"]="tar"

    # System utilities
    ["htop"]="htop"
    ["btop"]="btop"
    ["tree"]="tree"
    ["ncdu"]="ncdu"
    ["tmux"]="tmux"
    ["screen"]="screen"
    ["lsof"]="lsof"
    ["strace"]="strace"
    ["ltrace"]="ltrace"
    ["gdb"]="gdb"
    ["valgrind"]="valgrind"
    ["man-db"]="man-db"
    ["manpages-dev"]="man-pages"
    ["info"]="info"
    ["sudo"]="sudo"
    ["cron"]="cronie"
    ["at"]="at"
    ["rsync"]="rsync"
    ["sshfs"]="fuse-sshfs"
    ["fuse"]="fuse"
    ["bc"]="bc"
    ["jq"]="jq"
    ["yq"]="yq"
    ["less"]="less"
    ["file"]="file"
    ["patch"]="patch"
    ["diffutils"]="diffutils"
    ["findutils"]="findutils"
    ["procps"]="procps-ng"
    ["psmisc"]="psmisc"
    ["util-linux"]="util-linux"
    ["lshw"]="lshw"
    ["hwinfo"]="hwinfo"
    ["pciutils"]="pciutils"
    ["usbutils"]="usbutils"
    ["dmidecode"]="dmidecode"
    ["smartmontools"]="smartmontools"
    ["hdparm"]="hdparm"
    ["nvme-cli"]="nvme-cli"
    ["parted"]="parted"
    ["gparted"]="gparted"
    ["dosfstools"]="dosfstools"
    ["e2fsprogs"]="e2fsprogs"
    ["xfsprogs"]="xfsprogs"
    ["btrfs-progs"]="btrfs-progs"
    ["ntfs-3g"]="ntfs-3g"
    ["exfatprogs"]="exfatprogs"

    # Text editors
    ["vim"]="vim"
    ["vim-gtk3"]="vim-X11"
    ["neovim"]="neovim"
    ["emacs"]="emacs"
    ["nano"]="nano"
    ["gedit"]="gedit"

    # Shell & terminal
    ["bash"]="bash"
    ["zsh"]="zsh"
    ["fish"]="fish"
    ["bash-completion"]="bash-completion"
    ["command-not-found"]="PackageKit-command-not-found"
    ["gnome-terminal"]="gnome-terminal"
    ["kitty"]="kitty"
    ["alacritty"]="alacritty"
    ["tilix"]="tilix"

    # Version control
    ["git"]="git"
    ["git-lfs"]="git-lfs"
    ["subversion"]="subversion"
    ["mercurial"]="mercurial"

    # Containers & virtualisation
    ["docker.io"]="docker"
    ["docker-ce"]="docker-ce"
    ["docker-compose"]="docker-compose"
    ["podman"]="podman"
    ["buildah"]="buildah"
    ["skopeo"]="skopeo"
    ["qemu-kvm"]="qemu-kvm"
    ["libvirt-daemon"]="libvirt"
    ["virt-manager"]="virt-manager"
    ["virtualbox"]="VirtualBox"

    # Databases
    ["sqlite3"]="sqlite"
    ["libsqlite3-dev"]="sqlite-devel"
    ["postgresql"]="postgresql"
    ["postgresql-client"]="postgresql"
    ["libpq-dev"]="postgresql-devel"
    ["mysql-server"]="mysql-server"
    ["mysql-client"]="mysql"
    ["libmysqlclient-dev"]="mysql-devel"
    ["mariadb-server"]="mariadb-server"
    ["mariadb-client"]="mariadb"
    ["redis"]="redis"
    ["redis-server"]="redis"
    ["mongodb"]="mongodb-org"

    # Web / HTTP
    ["apache2"]="httpd"
    ["nginx"]="nginx"
    ["certbot"]="certbot"
    ["libapache2-mod-ssl"]="mod_ssl"

    # Libraries (common)
    ["libssl-dev"]="openssl-devel"
    ["libcurl4-openssl-dev"]="libcurl-devel"
    ["libxml2-dev"]="libxml2-devel"
    ["libxslt1-dev"]="libxslt-devel"
    ["libz-dev"]="zlib-devel"
    ["zlib1g-dev"]="zlib-devel"
    ["libffi-dev"]="libffi-devel"
    ["libreadline-dev"]="readline-devel"
    ["libncurses-dev"]="ncurses-devel"
    ["libbz2-dev"]="bzip2-devel"
    ["liblzma-dev"]="xz-devel"
    ["libgmp-dev"]="gmp-devel"
    ["libpcre2-dev"]="pcre2-devel"
    ["libevent-dev"]="libevent-devel"
    ["libboost-dev"]="boost-devel"
    ["libboost-all-dev"]="boost-devel"
    ["libjpeg-dev"]="libjpeg-turbo-devel"
    ["libpng-dev"]="libpng-devel"
    ["libgif-dev"]="giflib-devel"
    ["libwebp-dev"]="libwebp-devel"
    ["libtiff-dev"]="libtiff-devel"
    ["libfreetype-dev"]="freetype-devel"
    ["libfontconfig-dev"]="fontconfig-devel"
    ["libcairo2-dev"]="cairo-devel"
    ["libpango1.0-dev"]="pango-devel"
    ["libglib2.0-dev"]="glib2-devel"
    ["libgtk-3-dev"]="gtk3-devel"
    ["libgtk-4-dev"]="gtk4-devel"
    ["libqt5-dev"]="qt5-devel"
    ["qtbase5-dev"]="qt5-qtbase-devel"
    ["libdbus-1-dev"]="dbus-devel"
    ["libsystemd-dev"]="systemd-devel"
    ["libudev-dev"]="systemd-devel"
    ["libusb-dev"]="libusb-devel"
    ["libusb-1.0-0-dev"]="libusbx-devel"
    ["libhidapi-dev"]="hidapi-devel"
    ["libbluetooth-dev"]="bluez-libs-devel"
    ["libasound2-dev"]="alsa-lib-devel"
    ["libpulse-dev"]="pulseaudio-libs-devel"
    ["libpipewire-0.3-dev"]="pipewire-devel"

    # X11 / Wayland / graphics
    ["xorg"]="xorg-x11-server-Xorg"
    ["x11-xserver-utils"]="xorg-x11-server-utils"
    ["x11-utils"]="xorg-x11-utils"
    ["xclip"]="xclip"
    ["xdotool"]="xdotool"
    ["libx11-dev"]="libX11-devel"
    ["libxext-dev"]="libXext-devel"
    ["libxrender-dev"]="libXrender-devel"
    ["libxrandr-dev"]="libXrandr-devel"
    ["libxi-dev"]="libXi-devel"
    ["mesa-vulkan-drivers"]="mesa-vulkan-drivers"
    ["libvulkan-dev"]="vulkan-devel"
    ["libgl-dev"]="mesa-libGL-devel"
    ["libegl-dev"]="mesa-libEGL-devel"
    ["libgles-dev"]="mesa-libGLES-devel"
    ["libwayland-dev"]="wayland-devel"

    # Fonts
    ["fonts-dejavu"]="dejavu-fonts-all"
    ["fonts-liberation"]="liberation-fonts"
    ["fonts-noto"]="google-noto-fonts-common"
    ["ttf-mscorefonts-installer"]="cabextract"   # closest available

    # Multimedia
    ["ffmpeg"]="ffmpeg"
    ["vlc"]="vlc"
    ["gstreamer1.0-tools"]="gstreamer1-tools"
    ["gstreamer1.0-plugins-good"]="gstreamer1-plugins-good"
    ["gstreamer1.0-plugins-bad"]="gstreamer1-plugins-bad-free"
    ["gstreamer1.0-plugins-ugly"]="gstreamer1-plugins-ugly"
    ["libgstreamer1.0-dev"]="gstreamer1-devel"
    ["v4l-utils"]="v4l-utils"

    # Printing
    ["cups"]="cups"
    ["printer-driver-gutenprint"]="gutenprint"

    # Bluetooth
    ["bluez"]="bluez"
    ["blueman"]="blueman"

    # Security
    ["gnupg"]="gnupg2"
    ["gnupg2"]="gnupg2"
    ["pass"]="pass"
    ["keepassxc"]="keepassxc"
    ["fail2ban"]="fail2ban"
    ["apparmor"]="apparmor"          # not default on Fedora; SELinux is
    ["libpam-google-authenticator"]="google-authenticator"
    ["auditd"]="audit"
    ["rkhunter"]="rkhunter"
    ["clamav"]="clamav"

    # Node.js / JavaScript
    ["nodejs"]="nodejs"
    ["npm"]="npm"
    ["yarn"]="yarnpkg"

    # Ruby
    ["ruby"]="ruby"
    ["ruby-dev"]="ruby-devel"
    ["rubygems"]="rubygems"

    # Go
    ["golang"]="golang"
    ["golang-go"]="golang"

    # Rust
    ["rustc"]="rust"
    ["cargo"]="cargo"

    # .NET
    ["dotnet-sdk-8"]="dotnet-sdk-8.0"
    ["dotnet-runtime-8"]="dotnet-runtime-8.0"
    ["aspnetcore-runtime-8"]="aspnetcore-runtime-8.0"

    # Power management
    ["tlp"]="tlp"
    ["powertop"]="powertop"
    ["thermald"]="thermald"

    # Desktop environment components (GNOME)
    ["gnome-shell"]="gnome-shell"
    ["gnome-tweaks"]="gnome-tweaks"
    ["gnome-extensions-app"]="gnome-extensions-app"
    ["nautilus"]="nautilus"
    ["evince"]="evince"
    ["eog"]="eog"
    ["totem"]="totem"
    ["rhythmbox"]="rhythmbox"
    ["shotwell"]="shotwell"

    # Archive / packaging
    ["dpkg"]="rpm"                   # cross-distro note
    ["apt"]="dnf"

    # Misc CLI tools
    ["fzf"]="fzf"
    ["ripgrep"]="ripgrep"
    ["fd-find"]="fd-find"
    ["bat"]="bat"
    ["exa"]="eza"
    ["eza"]="eza"
    ["lsd"]="lsd"
    ["dust"]="dust"
    ["duf"]="duf"
    ["bottom"]="bottom"
    ["gitui"]="gitui"
    ["lazygit"]="lazygit"
    ["neofetch"]="neofetch"
    ["screenfetch"]="screenfetch"
    ["speedtest-cli"]="speedtest-cli"
    ["iperf3"]="iperf3"
    ["mtr"]="mtr"
    ["traceroute"]="traceroute"
    ["whois"]="whois"
    ["tcpdump"]="tcpdump"
    ["wireshark"]="wireshark"
    ["tshark"]="wireshark-cli"
    ["socat"]="socat"
    ["ncat"]="ncat"
    ["sshpass"]="sshpass"
    ["expect"]="expect"
    ["dialog"]="dialog"
    ["whiptail"]="newt"
    ["parallel"]="parallel"
    ["pv"]="pv"
    ["mbuffer"]="mbuffer"
    ["pigz"]="pigz"
    ["pixz"]="pixz"
    ["unar"]="unar"
    ["cabextract"]="cabextract"
    ["inxi"]="inxi"
    ["cpufrequtils"]="cpufrequtils"
    ["acpi"]="acpi"
    ["lm-sensors"]="lm_sensors"
    ["fancontrol"]="lm_sensors"
    ["i2c-tools"]="i2c-tools"
    ["ddcutil"]="ddcutil"
    ["xsensors"]="xsensors"
    ["stress"]="stress"
    ["stress-ng"]="stress-ng"
    ["sysbench"]="sysbench"
    ["fio"]="fio"
    ["iotop"]="iotop"
    ["nethogs"]="nethogs"
    ["iftop"]="iftop"
    ["bmon"]="bmon"
    ["glances"]="glances"
)

# ---------------------------------------------------------------------------
# Packages to skip entirely on cross-distro migration
# (Debian/Ubuntu-specific with no meaningful equivalent)
# ---------------------------------------------------------------------------
SKIP_PACKAGES=(
    "ubuntu-advantage-tools"
    "ubuntu-release-upgrader-core"
    "ubuntu-minimal"
    "ubuntu-standard"
    "ubuntu-desktop"
    "update-manager-core"
    "update-notifier-common"
    "apt-transport-https"
    "apt-utils"
    "debconf"
    "debianutils"
    "debsums"
    "dh-python"
    "dkms"              # present on Fedora too but kernel module framework differs
    "dpkg-dev"
    "gnome-software-plugin-snap"
    "snapd"             # replaced by Flatpak on Fedora
    "snap-store"
    "ubuntu-drivers-common"
    "linux-generic"
    "linux-image-generic"
    "linux-headers-generic"
    "linux-firmware"    # different package name; pre-installed on Fedora
    "grub-pc"
    "grub2-common"
    "plymouth"
    "initramfs-tools"
    "dracut"
    "systemd-sysv"
    "libnss-systemd"
    "libpam-systemd"
    "base-files"
    "base-passwd"
    "hostname"
    "login"
    "adduser"
    "shadow"
)

# ---------------------------------------------------------------------------
# Resolve a Debian package name to its target equivalent
# Returns:
#   0 + prints rpm_name  → available (possibly renamed)
#   1                    → skip (Debian-only meta-package)
#   2                    → unknown / manual check needed
# ---------------------------------------------------------------------------
resolve_package_name() {
    local deb_pkg="$1"

    # Check skip list
    for skip in "${SKIP_PACKAGES[@]}"; do
        if [[ "${deb_pkg}" == "${skip}" ]]; then
            return 1
        fi
    done

    if [[ "${TARGET_FAMILY}" == "ubuntu" ]]; then
        # Same ecosystem — name is unchanged
        echo "${deb_pkg}"
        return 0
    fi

    # Cross-distro: look up translation table
    if [[ -v DEB_TO_RPM["${deb_pkg}"] ]]; then
        echo "${DEB_TO_RPM[${deb_pkg}]}"
        return 0
    fi

    # Not in table — assume same name might exist (dnf will tell us)
    echo "${deb_pkg}"
    return 2
}

# ---------------------------------------------------------------------------
# API availability checks
# ---------------------------------------------------------------------------
UBUNTU_PKG_API="https://packages.ubuntu.com/search?suite=${TARGET_VERSION}&searchon=names&exact=1&keywords="
# Fedora's MDApi JSON endpoint
FEDORA_PKG_API="https://mdapi.fedoraproject.org/fedora-${TARGET_VERSION}/pkg/"
# RHEL uses Red Hat Package Browser (public)
RHEL_PKG_API="https://access.redhat.com/downloads/content/package-browser/json?q="

check_ubuntu() {
    local pkg="$1"
    local result
    result=$(HTTP_GET "${UBUNTU_PKG_API}${pkg}") || return 2
    if   echo "${result}" | grep -q "No packages found";    then return 1
    elif echo "${result}" | grep -qi "packages matching";   then return 0
    else return 2
    fi
}

check_fedora() {
    local pkg="$1"
    local result http_code
    # mdapi returns 200 with JSON if found, 404 if not
    if command -v curl &>/dev/null; then
        http_code=$(curl -o /dev/null -s -w "%{http_code}" --max-time 10 \
            "${FEDORA_PKG_API}${pkg}" 2>/dev/null || echo "000")
    else
        result=$(wget -qO- --timeout=10 "${FEDORA_PKG_API}${pkg}" 2>/dev/null || true)
        [[ -n "${result}" ]] && http_code="200" || http_code="404"
    fi
    case "${http_code}" in
        200) return 0 ;;
        404) return 1 ;;
        *)   return 2 ;;
    esac
}

check_package_availability() {
    local pkg="$1"
    case "${TARGET_FAMILY}" in
        ubuntu) check_ubuntu  "${pkg}"; return $? ;;
        fedora) check_fedora  "${pkg}"; return $? ;;
        rhel)   check_fedora  "${pkg}"; return $? ;;   # mdapi works for EPEL/RHEL too
    esac
}

# Check if local dnf/apt-cache can answer faster
USE_LOCAL=false
if [[ "${TARGET_FAMILY}" == "ubuntu" ]] && command -v apt-cache &>/dev/null; then
    if grep -qr "${TARGET_VERSION}" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
        USE_LOCAL=true
        log "Target repos found in apt sources — using local apt-cache (fast)."
    fi
fi

# ---------------------------------------------------------------------------
# Step 1: Collect installed packages from this (Debian/Ubuntu) system
# ---------------------------------------------------------------------------
log "Collecting installed packages from current system..."

if ! command -v dpkg &>/dev/null; then
    err "dpkg not found — this script must be run on a Debian/Ubuntu system."
    exit 1
fi

if command -v apt-mark &>/dev/null; then
    INSTALLED_PACKAGES=$(apt-mark showmanual 2>/dev/null | sort -u)
    SOURCE="apt-mark showmanual (manually installed)"
else
    warn "apt-mark not found; using dpkg (includes auto-installed packages)."
    INSTALLED_PACKAGES=$(dpkg --get-selections | awk '$2=="install"{print $1}' \
        | sed 's/:.*$//' | sort -u)
    SOURCE="dpkg --get-selections"
fi

TOTAL=$(echo "${INSTALLED_PACKAGES}" | grep -c . || true)
log "Found ${TOTAL} packages via ${SOURCE}."

# ---------------------------------------------------------------------------
# Step 2: Resolve and check each package
# ---------------------------------------------------------------------------
log "Checking availability on target (${TARGET_FAMILY} ${TARGET_VERSION})..."
[[ "${TARGET_FAMILY}" != "ubuntu" ]] && \
    log "Cross-distro mode: applying Debian→RPM name translations."

declare -A RESULT_MAP    # deb_name → "available:rpm_name" | "unavailable" | "skip" | "unknown"

AVAILABLE_PKGS=()        # rpm names to install
UNAVAILABLE_PKGS=()      # deb names with explanation
SKIPPED_PKGS=()          # Debian-specific, intentionally dropped
RENAMED_PKGS=()          # deb_name → rpm_name (for report)
CHECKED=0

while IFS= read -r deb_pkg; do
    [[ -z "${deb_pkg}" ]] && continue
    CHECKED=$((CHECKED + 1))
    (( CHECKED % 25 == 0 )) && log "Progress: ${CHECKED}/${TOTAL}..."

    # Resolve name
    resolve_status=0
    rpm_name=$(resolve_package_name "${deb_pkg}") || resolve_status=$?

    # Intentional skip
    if [[ ${resolve_status} -eq 1 ]]; then
        SKIPPED_PKGS+=("${deb_pkg}")
        continue
    fi

    was_renamed=false
    [[ "${rpm_name}" != "${deb_pkg}" ]] && was_renamed=true

    # Availability check
    if [[ "${USE_LOCAL}" == true ]]; then
        if apt-cache show "${rpm_name}" &>/dev/null; then avail=0; else avail=1; fi
    else
        avail=0
        check_package_availability "${rpm_name}" || avail=$?
        sleep 0.08   # be polite to the API
    fi

    case ${avail} in
        0)
            # Handle multi-package translations (space-separated rpm names)
            for rname in ${rpm_name}; do
                AVAILABLE_PKGS+=("${rname}")
            done
            if [[ "${was_renamed}" == true ]]; then
                RENAMED_PKGS+=("${deb_pkg} → ${rpm_name}")
            fi
            ;;
        1)
            UNAVAILABLE_PKGS+=("${deb_pkg} (tried: ${rpm_name})")
            ;;
        2)
            # Unknown — include with a flag so the user can verify
            for rname in ${rpm_name}; do
                AVAILABLE_PKGS+=("${rname}")
            done
            UNAVAILABLE_PKGS+=("${deb_pkg} [UNVERIFIED — included anyway as: ${rpm_name}]")
            ;;
    esac

done <<< "${INSTALLED_PACKAGES}"

# Deduplicate available list
mapfile -t AVAILABLE_PKGS < <(printf '%s\n' "${AVAILABLE_PKGS[@]}" | sort -u)

# ---------------------------------------------------------------------------
# Step 3: Write output files
# ---------------------------------------------------------------------------
mkdir -p "${OUTPUT_DIR}"

AVAIL_COUNT=${#AVAILABLE_PKGS[@]}
UNAVAIL_COUNT=${#UNAVAILABLE_PKGS[@]}
SKIP_COUNT=${#SKIPPED_PKGS[@]}
RENAME_COUNT=${#RENAMED_PKGS[@]}

# packages_to_install.txt — one package per line, comment header
{
    echo "# Generated by audit_packages.sh on $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# Source: ${SOURCE}"
    echo "# Target: ${TARGET_FAMILY} ${TARGET_VERSION}"
    echo "# Pass this file to install_packages.sh"
    echo "#"
    printf '%s\n' "${AVAILABLE_PKGS[@]}"
} > "${INSTALL_LIST}"

# packages_unavailable.txt
{
    echo "# Packages NOT found in ${TARGET_FAMILY} ${TARGET_VERSION}"
    echo "# Consider: Flatpak, AppImage, build from source, or alternative packages"
    echo "#"
    printf '%s\n' "${UNAVAILABLE_PKGS[@]}"
} > "${UNAVAILABLE_LIST}"

# audit_report.txt
{
    echo "============================================================"
    echo "  Package Migration Audit Report"
    echo "  Generated : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Host      : $(hostname)"
    echo "  Source OS : $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
    echo "  Target    : ${TARGET_FAMILY^} ${TARGET_VERSION}"
    echo "  Method    : $( [[ "${USE_LOCAL}" == true ]] && echo "local apt-cache" || echo "package API" )"
    echo "============================================================"
    echo ""
    echo "SUMMARY"
    echo "-------"
    printf "  Total packages audited       : %d\n" "${TOTAL}"
    printf "  Available on target          : %d\n" "${AVAIL_COUNT}"
    printf "  Not available / no match     : %d\n" "${UNAVAIL_COUNT}"
    printf "  Skipped (Debian-specific)    : %d\n" "${SKIP_COUNT}"
    [[ "${TARGET_FAMILY}" != "ubuntu" ]] && \
    printf "  Renamed (deb → rpm)          : %d\n" "${RENAME_COUNT}"
    echo ""

    if [[ "${TARGET_FAMILY}" != "ubuntu" && ${RENAME_COUNT} -gt 0 ]]; then
        echo "============================================================"
        echo "  PACKAGE NAME TRANSLATIONS (${RENAME_COUNT})"
        echo "============================================================"
        printf '  %s\n' "${RENAMED_PKGS[@]}"
        echo ""
    fi

    echo "============================================================"
    echo "  PACKAGES AVAILABLE ON TARGET (${AVAIL_COUNT})"
    echo "============================================================"
    printf '  %s\n' "${AVAILABLE_PKGS[@]}"
    echo ""

    echo "============================================================"
    echo "  PACKAGES NOT AVAILABLE ON TARGET (${UNAVAIL_COUNT})"
    if [[ "${TARGET_FAMILY}" != "ubuntu" ]]; then
        echo "  Tip: try 'dnf search <name>', Flatpak, or AppImage"
    else
        echo "  Tip: try PPAs, Snap, Flatpak, or build from source"
    fi
    echo "============================================================"
    printf '  %s\n' "${UNAVAILABLE_PKGS[@]}"
    echo ""

    echo "============================================================"
    echo "  SKIPPED — DEBIAN/UBUNTU-SPECIFIC PACKAGES (${SKIP_COUNT})"
    echo "============================================================"
    printf '  %s\n' "${SKIPPED_PKGS[@]}"
    echo ""

    echo "OUTPUT FILES"
    echo "------------"
    echo "  Install list  : ${INSTALL_LIST}"
    echo "  Unavailable   : ${UNAVAILABLE_LIST}"
    echo "  This report   : ${REPORT_FILE}"
} > "${REPORT_FILE}"

# ---------------------------------------------------------------------------
# Terminal summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Audit complete${RESET}"
echo -e "${BOLD}════════════════════════════════════════${RESET}"
ok   "Available on ${TARGET_FAMILY^} ${TARGET_VERSION} : ${AVAIL_COUNT} packages"
[[ ${RENAME_COUNT} -gt 0 ]] && \
info "  (${RENAME_COUNT} of those were renamed deb→rpm)"
warn "Not available / manual       : ${UNAVAIL_COUNT}"
log  "Skipped (Debian-specific)    : ${SKIP_COUNT}"
echo ""
log "Report       → ${REPORT_FILE}"
log "Install list → ${INSTALL_LIST}"
log "Unavailable  → ${UNAVAILABLE_LIST}"
echo ""
if [[ "${TARGET_FAMILY}" == "ubuntu" ]]; then
    echo -e "On the new Ubuntu system run:"
    echo -e "  ${BOLD}sudo ./install_packages.sh ${INSTALL_LIST}${RESET}"
else
    echo -e "On the new ${TARGET_FAMILY^} system run:"
    echo -e "  ${BOLD}sudo ./install_packages.sh ${INSTALL_LIST} --distro ${TARGET_FAMILY}${RESET}"
fi
echo ""
