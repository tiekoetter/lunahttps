#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly NGINX_VERSION="1.29.8"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly PROJECT_ROOT="${SCRIPT_DIR}"
readonly LUNA_DIR="${PROJECT_ROOT}/luna"
readonly NGINX_INTERNALS_DIR="${LUNA_DIR}/nginx-internals"
readonly BRANDING_PATCH_SCRIPT="${LUNA_DIR}/branding-patch.sh"
readonly OPENSSL_DIR="${LUNA_DIR}/openssl-lts"
readonly MODULES_DIR="${LUNA_DIR}/modules"
readonly BUILD_ROOT="${LUNA_DIR}/build"
readonly BUILD_DIR="${BUILD_ROOT}/nginx-build-${NGINX_VERSION}"
readonly NGINX_TARBALL="nginx-${NGINX_VERSION}.tar.gz"
readonly NGINX_URL="https://nginx.org/download/${NGINX_TARBALL}"
readonly SRC_DIR="${BUILD_DIR}/nginx-${NGINX_VERSION}"

LIGHTBLUE=$'\033[1;34m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
PURPLE=$'\033[0;35m'
NC=$'\033[0m'

log() {
    printf '%b\n' "${LIGHTBLUE}$*${NC}"
}

warn() {
    printf '%b\n' "${YELLOW}Warning: $*${NC}" >&2
}

die() {
    printf '%b\n' "${RED}Error: $*${NC}" >&2
    exit 1
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

ensure_dir() {
    mkdir -p "$1"
}

print_banner() {
    printf '%b\n' "*******************************************************
          ${PURPLE}Tiekoetter.net Luna-HTTP/S Builder v2${NC}

 Working with NGINX Version \"${NGINX_VERSION}\"
 OpenSSL with TLS 1.3 Support + kTLS
 HTTP3 / QUIC (experimental)

 ngx_brotli
 ngx_http_geoip2_module
 headers-more-nginx-module
 ngx_http_substitutions_filter_module

 Copyright © 2018-2026 Léon Tiekötter <leon@tiekoetter.com>
*******************************************************"
}

check_environment() {
    [[ "${EUID}" -eq 0 ]] || die "Please run this script as root."

    require_command wget
    require_command tar
    require_command make
    require_command systemctl
    require_command nproc
    require_command bash
    require_command perl

    ensure_dir "${LUNA_DIR}"
    ensure_dir "${NGINX_INTERNALS_DIR}"
    ensure_dir "${OPENSSL_DIR}"
    ensure_dir "${MODULES_DIR}"
    ensure_dir "${BUILD_ROOT}"

    ensure_dir "${MODULES_DIR}/ngx_http_substitutions_filter_module"
    ensure_dir "${MODULES_DIR}/headers-more-nginx-module"
    ensure_dir "${MODULES_DIR}/ngx_http_geoip2_module"
    ensure_dir "${MODULES_DIR}/ngx_brotli"

    require_file "${LUNA_DIR}/openssl-downloader.sh"
    require_file "${BRANDING_PATCH_SCRIPT}"
    require_file "${NGINX_INTERNALS_DIR}/ngx_http_header_filter_module.c"
    require_file "${NGINX_INTERNALS_DIR}/ngx_http_special_response.c"
    require_file "${MODULES_DIR}/ngx_http_substitutions_filter_module/config"
    require_file "${MODULES_DIR}/headers-more-nginx-module/config"
    require_file "${MODULES_DIR}/ngx_http_geoip2_module/config"
    require_file "${MODULES_DIR}/ngx_brotli/config"
}

download_openssl() {
    log "Starting OpenSSL downloader..."
    cd "${LUNA_DIR}"
    bash "./openssl-downloader.sh"
}

prepare_build_dir() {
    log "Preparing clean build directory..."
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"
}

download_nginx() {
    log "Downloading NGINX ${NGINX_VERSION}..."
    cd "${BUILD_DIR}"
    wget -O "${NGINX_TARBALL}" "${NGINX_URL}"
    tar -xzf "${NGINX_TARBALL}"
    [[ -d "${SRC_DIR}" ]] || die "Extracted source directory not found: ${SRC_DIR}"
}

patch_nginx() {
    log "Applying Luna-HTTP/S branding patch..."
    cd "${SRC_DIR}"
    bash "${BRANDING_PATCH_SCRIPT}"

    grep -RIn 'luna-http/s\|Luna-HTTP/S' \
        "src/http/ngx_http_header_filter_module.c" \
        "src/http/ngx_http_special_response.c" \
        "src/http/v2/ngx_http_v2_filter_module.c" \
        "src/http/v3/ngx_http_v3_filter_module.c" >/dev/null || \
        die "Luna branding patch did not apply correctly."
}

configure_nginx() {
    log "Configuring Luna-HTTP/S..."
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

build_nginx() {
    log "Building Luna-HTTP/S..."
    cd "${SRC_DIR}"
    make -j"$(nproc)"
}

install_nginx() {
    log "Installing Luna-HTTP/S..."
    cd "${SRC_DIR}"
    make install
}

validate_nginx() {
    log "Validating installed NGINX configuration..."
    /usr/sbin/nginx -t
}

restart_nginx() {
    log "Restarting NGINX..."
    systemctl restart nginx
    systemctl --no-pager --full status nginx || die "NGINX restart failed."
}

main() {
    print_banner
    check_environment
    download_openssl
    prepare_build_dir
    download_nginx
    patch_nginx
    configure_nginx
    build_nginx
    install_nginx
    validate_nginx
    restart_nginx

    printf '\n%b\n' "${GREEN}Done.${NC} Luna-HTTP/S is now active and online!"
}

main "$@"
