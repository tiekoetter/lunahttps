#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly NGINX_VERSION="1.31.5"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly LUNA_DIR="${SCRIPT_DIR}/luna"
readonly BRANDING_PATCH_SCRIPT="${LUNA_DIR}/branding-patch.sh"
readonly NGINX_SIGNING_KEYS_FILE="${LUNA_DIR}/nginx-signing-keys.txt"
readonly OPENSSL_DIR="${LUNA_DIR}/openssl-lts"
readonly MODULES_DIR="${LUNA_DIR}/modules"
readonly BUILD_ROOT="${LUNA_DIR}/build"
readonly BUILD_DIR="${BUILD_ROOT}/nginx-build-${NGINX_VERSION}"
readonly NGINX_TARBALL="nginx-${NGINX_VERSION}.tar.gz"
readonly NGINX_SIGNATURE="${NGINX_TARBALL}.asc"
readonly NGINX_URL="https://nginx.org/download/${NGINX_TARBALL}"
readonly NGINX_SIGNATURE_URL="${NGINX_URL}.asc"
readonly SRC_DIR="${BUILD_DIR}/nginx-${NGINX_VERSION}"

BUILD_MODE="host"

LIGHTBLUE=$'\033[1;34m'
GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
PURPLE=$'\033[0;35m'
NC=$'\033[0m'

log() {
    printf '%b\n' "${LIGHTBLUE}$*${NC}"
}

die() {
    printf '%b\n' "${RED}Error: $*${NC}" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $0 [--host|--docker]

Modes:
  --host    Build, install, validate, and restart the Luna-HTTP/S service.
  --docker  Build and install only; intended for Docker builder stages.
EOF
}

cleanup_on_error() {
    local exit_code=$?
    printf '%b\n' "${RED}Build failed (exit code ${exit_code}) near line ${BASH_LINENO[0]:-unknown}.${NC}" >&2
    exit "${exit_code}"
}

trap cleanup_on_error ERR

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_file() {
    [[ -f "$1" ]] || die "Required file not found: $1"
}

download_file() {
    local destination="$1"
    local url="$2"

    curl --fail --location --show-error \
        --retry 3 --retry-all-errors --connect-timeout 30 \
        --proto '=https' --proto-redir '=https' \
        --output "${destination}" "${url}"
}

print_banner() {
    printf '%b\n' "*******************************************************
              ${PURPLE}Luna-HTTP/S Builder${NC}

 Project:        Luna-HTTP/S
 Mode:           ${BUILD_MODE}
 Upstream:       NGINX ${NGINX_VERSION}
 TLS stack:      OpenSSL LTS with TLS 1.3 and kTLS
 Protocols:      HTTP/1.1, HTTP/2, HTTP/3 / QUIC

 Built-in modules:
   - ngx_brotli
   - ngx_http_realip_module
   - ngx_http_geoip2_module
   - headers-more-nginx-module
   - ngx_http_substitutions_filter_module

 Copyright © 2018-2026 Léon Tiekötter <leon@tiekoetter.com>
*******************************************************"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)
                BUILD_MODE="host"
                ;;
            --docker)
                BUILD_MODE="docker"
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
        shift
    done
}

check_environment() {
    [[ "${EUID}" -eq 0 ]] || die "Please run this script as root."

    require_command curl
    require_command gpg
    require_command awk
    require_command tar
    require_command make
    require_command nproc
    require_command perl

    if [[ "${BUILD_MODE}" == "host" ]]; then
        require_command systemctl
    fi

    require_file "${LUNA_DIR}/openssl-downloader.sh"
    require_file "${LUNA_DIR}/openssl-version.env"
    require_file "${NGINX_SIGNING_KEYS_FILE}"
    require_file "${BRANDING_PATCH_SCRIPT}"
    require_file "${MODULES_DIR}/ngx_http_substitutions_filter_module/config"
    require_file "${MODULES_DIR}/headers-more-nginx-module/config"
    require_file "${MODULES_DIR}/ngx_http_geoip2_module/config"
    require_file "${MODULES_DIR}/ngx_brotli/config"
    require_file "${MODULES_DIR}/ngx_brotli/deps/brotli/c/include/brotli/encode.h"
}

download_openssl() {
    log "Preparing Luna-HTTP/S OpenSSL source..."
    cd "${LUNA_DIR}"
    "${BASH}" "./openssl-downloader.sh"
}

prepare_build_dir() {
    log "Preparing clean Luna-HTTP/S build directory..."
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"
}

verify_upstream_signature() {
    log "Verifying upstream NGINX release signature..."

    local gnupg_home="${BUILD_DIR}/gnupg"
    local key_file
    local key_metadata
    local expected_fingerprint
    local key_url
    local extra
    local actual_fingerprint
    local primary_key_count
    local imported_key_count=0
    local verify_status
    local valid_fingerprint

    rm -rf "${gnupg_home}"
    mkdir -p "${gnupg_home}"
    chmod 700 "${gnupg_home}"

    while IFS=$' \t' read -r expected_fingerprint key_url extra <&3 || \
        [[ -n "${expected_fingerprint}${key_url}${extra}" ]]; do
        [[ -z "${expected_fingerprint}" || "${expected_fingerprint}" == \#* ]] && continue

        [[ -z "${extra}" ]] || \
            die "Malformed NGINX signing key entry: ${expected_fingerprint} ${key_url} ${extra}"
        [[ "${expected_fingerprint}" =~ ^[A-F0-9]{40}$ ]] || \
            die "Invalid NGINX signing key fingerprint: ${expected_fingerprint}"
        [[ "${key_url}" == https://nginx.org/keys/*.key ]] || \
            die "Invalid NGINX signing key URL: ${key_url}"

        key_file="${BUILD_DIR}/nginx-signing-key-${imported_key_count}.key"
        key_metadata="${BUILD_DIR}/nginx-signing-key-${imported_key_count}.txt"

        download_file "${key_file}" "${key_url}"
        GNUPGHOME="${gnupg_home}" gpg --batch --no-autostart --with-colons --import-options show-only --import "${key_file}" > "${key_metadata}"

        primary_key_count="$(awk -F: '$1 == "pub" { count++ } END { print count + 0 }' "${key_metadata}")"
        [[ "${primary_key_count}" -eq 1 ]] || \
            die "Expected exactly one primary key in ${key_url}, found ${primary_key_count}."

        actual_fingerprint="$(awk -F: '$1 == "fpr" { print $10; exit }' "${key_metadata}")"
        [[ "${actual_fingerprint}" == "${expected_fingerprint}" ]] || \
            die "Unexpected NGINX signing key fingerprint from ${key_url}: ${actual_fingerprint}"

        GNUPGHOME="${gnupg_home}" gpg --batch --no-autostart --import "${key_file}" >/dev/null
        rm -f "${key_file}" "${key_metadata}"
        imported_key_count=$((imported_key_count + 1))
    done 3< "${NGINX_SIGNING_KEYS_FILE}"

    [[ "${imported_key_count}" -gt 0 ]] || \
        die "No trusted NGINX signing keys configured in ${NGINX_SIGNING_KEYS_FILE}."

    if ! verify_status="$(GNUPGHOME="${gnupg_home}" gpg --batch --no-autostart --status-fd 1 --verify "${BUILD_DIR}/${NGINX_SIGNATURE}" "${BUILD_DIR}/${NGINX_TARBALL}")"; then
        die "Upstream NGINX release signature verification failed."
    fi

    valid_fingerprint="$(awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { print (length($NF) == 40 ? $NF : $3); exit }' <<< "${verify_status}")"
    [[ -n "${valid_fingerprint}" ]] || \
        die "GPG did not report a valid NGINX release signature."

    awk -v fingerprint="${valid_fingerprint}" '$1 == fingerprint { found = 1 } END { exit !found }' "${NGINX_SIGNING_KEYS_FILE}" || \
        die "Upstream NGINX release signature was not made by a pinned key: ${valid_fingerprint}"

    rm -rf "${gnupg_home}"
}

download_upstream_nginx() {
    log "Downloading upstream NGINX ${NGINX_VERSION}..."
    cd "${BUILD_DIR}"
    download_file "${NGINX_TARBALL}" "${NGINX_URL}"
    download_file "${NGINX_SIGNATURE}" "${NGINX_SIGNATURE_URL}"
    verify_upstream_signature
    tar -xzf "${NGINX_TARBALL}"
    [[ -d "${SRC_DIR}" ]] || die "Extracted source directory not found: ${SRC_DIR}"
    rm -f "${NGINX_TARBALL}" "${NGINX_SIGNATURE}"
}

apply_luna_patches() {
    log "Applying Luna-HTTP/S source patches..."
    cd "${SRC_DIR}"
    "${BASH}" "${BRANDING_PATCH_SCRIPT}"

    grep -RIn 'luna-http/s\|Luna-HTTP/S' \
        "src/http/ngx_http_header_filter_module.c" \
        "src/http/ngx_http_special_response.c" \
        "src/http/v2/ngx_http_v2_filter_module.c" \
        "src/http/v3/ngx_http_v3_filter_module.c" >/dev/null || \
        die "Luna-HTTP/S branding patch did not apply correctly."
}

configure_luna() {
    log "Configuring Luna-HTTP/S build..."
    cd "${SRC_DIR}"

    ./configure \
        --prefix=/usr/share/nginx \
        --sbin-path=/usr/sbin/nginx \
        --conf-path=/etc/nginx/nginx.conf \
        --pid-path=/var/run/nginx.pid \
        --lock-path=/var/lock/nginx.lock \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --user=www-data \
        --group=www-data \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_v3_module \
        --with-http_realip_module \
        --with-http_stub_status_module \
        --with-http_gzip_static_module \
        --with-http_sub_module \
        --with-file-aio \
        --with-threads \
        --with-stream \
        --with-stream_ssl_module \
        --with-pcre \
        --add-module="${MODULES_DIR}/ngx_http_substitutions_filter_module" \
        --add-module="${MODULES_DIR}/headers-more-nginx-module" \
        --add-module="${MODULES_DIR}/ngx_http_geoip2_module" \
        --add-module="${MODULES_DIR}/ngx_brotli" \
        --with-openssl="${OPENSSL_DIR}" \
        --with-openssl-opt=enable-ktls
}

build_luna() {
    log "Building Luna-HTTP/S..."
    cd "${SRC_DIR}"
    make -j"$(nproc)"
}

install_luna() {
    log "Installing Luna-HTTP/S..."
    cd "${SRC_DIR}"
    make install
}

validate_luna() {
    log "Validating installed Luna-HTTP/S configuration..."
    /usr/sbin/nginx -t
}

restart_luna() {
    log "Restarting Luna-HTTP/S service..."
    systemctl restart nginx
    systemctl --no-pager --full status nginx || die "Luna-HTTP/S service restart failed."
}

main() {
    parse_args "$@"

    print_banner
    check_environment
    download_openssl
    prepare_build_dir
    download_upstream_nginx
    apply_luna_patches
    configure_luna
    build_luna
    install_luna

    if [[ "${BUILD_MODE}" == "host" ]]; then
        validate_luna
        restart_luna
    fi

    if [[ "${BUILD_MODE}" == "docker" ]]; then
        printf '\n%b\n' "${GREEN}Done.${NC} Luna-HTTP/S is built and installed for the container image."
    else
        printf '\n%b\n' "${GREEN}Done.${NC} Luna-HTTP/S is now active and online!"
    fi
}

main "$@"
