#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly WORK_DIR="${SCRIPT_DIR}"
readonly OPENSSL_DIR="${WORK_DIR}/openssl-lts"
readonly TMP_ROOT="${WORK_DIR}/.tmp"
readonly DL_DIR="${TMP_ROOT}/openssl-download"
readonly OPENSSL_VERSION_FILE="${WORK_DIR}/openssl-version.env"
readonly RELEASE_BASE_URL="https://github.com/openssl/openssl/releases/download"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[1;34m'
NC=$'\033[0m'

__error_reported=0

log() {
    printf '%b\n' "${BLUE}$*${NC}"
}

warn() {
    printf '%b\n' "${YELLOW}Warning: $*${NC}" >&2
}

die() {
    printf '%b\n' "${RED}Error: $*${NC}" >&2
    exit 1
}

cleanup_on_error() {
    local exit_code=$1
    local line_no=$2

    if [[ $__error_reported -eq 0 ]]; then
        __error_reported=1
        printf '%b\n' "${RED}OpenSSL downloader failed (exit code ${exit_code}) near line ${line_no}.${NC}" >&2
    fi

    exit "${exit_code}"
}

trap 'cleanup_on_error $? $LINENO' ERR

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_file() {
    [[ -f "$1" ]] || die "Required file not found: $1"
}

safe_remove_dir() {
    local dir="$1"
    [[ -n "$dir" ]] || die "Refusing to remove empty path"
    [[ "$dir" != "/" ]] || die "Refusing to remove /"
    rm -rf -- "$dir"
}

load_openssl_pin() {
    require_file "${OPENSSL_VERSION_FILE}"

    # shellcheck source=luna/openssl-version.env
    . "${OPENSSL_VERSION_FILE}"

    [[ "${OPENSSL_SERIES:-}" =~ ^[0-9]+\.[0-9]+$ ]] || \
        die "Invalid OPENSSL_SERIES in ${OPENSSL_VERSION_FILE}"
    [[ "${OPENSSL_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
        die "Invalid OPENSSL_VERSION in ${OPENSSL_VERSION_FILE}"
    [[ "${OPENSSL_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || \
        die "Invalid OPENSSL_SHA256 in ${OPENSSL_VERSION_FILE}"
    [[ "${OPENSSL_VERSION}" == "${OPENSSL_SERIES}".* ]] || \
        die "OPENSSL_VERSION must belong to OPENSSL_SERIES in ${OPENSSL_VERSION_FILE}"

    readonly OPENSSL_SERIES OPENSSL_VERSION OPENSSL_SHA256
}

file_sha256() {
    local file="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        die "Required command not found: sha256sum or shasum"
    fi
}

verify_sha256() {
    local file="$1"
    local actual

    actual="$(file_sha256 "$file")"
    [[ "${actual}" == "${OPENSSL_SHA256}" ]] || \
        die "SHA256 mismatch for ${file}: expected ${OPENSSL_SHA256}, got ${actual}"
}

main() {
    require_command curl
    require_command awk
    require_command tar
    require_command mktemp
    require_command mv
    require_command cp
    load_openssl_pin

    log "Preparing temporary download directory..."
    mkdir -p "${TMP_ROOT}"
    safe_remove_dir "${DL_DIR}"
    mkdir -p "${DL_DIR}"

    cd "${DL_DIR}"

    FILENAME="openssl-${OPENSSL_VERSION}.tar.gz"
    DOWNLOAD_URL="${RELEASE_BASE_URL}/openssl-${OPENSSL_VERSION}/${FILENAME}"

    log "Downloading pinned OpenSSL ${OPENSSL_VERSION} from: ${DOWNLOAD_URL}"
    curl -fL --retry 3 --retry-all-errors -o "${FILENAME}" "${DOWNLOAD_URL}"

    [[ -s "${FILENAME}" ]] || die "Downloaded tarball is missing or empty: ${FILENAME}"

    log "Verifying ${FILENAME} SHA256..."
    verify_sha256 "${FILENAME}"

    log "Extracting ${FILENAME}..."
    tar -xzf "${FILENAME}"

    shopt -s nullglob
    entries=( "${DL_DIR}"/openssl-* )
    shopt -u nullglob

    extracted_dirs=()
    for entry in "${entries[@]}"; do
        if [[ -d "${entry}" ]]; then
            extracted_dirs+=( "${entry}" )
        fi
    done

    [[ ${#extracted_dirs[@]} -eq 1 ]] || die "Expected exactly one extracted OpenSSL directory, found ${#extracted_dirs[@]}."

    EXTRACTED_DIR="$(basename -- "${extracted_dirs[0]}")"

    case "${EXTRACTED_DIR}" in
        "openssl-${OPENSSL_VERSION}")
            ;;
        *)
            die "Unexpected extracted directory name: ${EXTRACTED_DIR}"
            ;;
    esac

    log "Replacing ${OPENSSL_DIR} atomically..."
    TMP_TARGET="$(mktemp -d "${TMP_ROOT}/openssl-lts.XXXXXX")"
    cp -a "${DL_DIR}/${EXTRACTED_DIR}/." "${TMP_TARGET}/"

    safe_remove_dir "${OPENSSL_DIR}"
    mv -- "${TMP_TARGET}" "${OPENSSL_DIR}"

    log "OpenSSL source prepared successfully."
    printf '%b\n' "${GREEN}Final directory:${NC}"
    ls -ld -- "${OPENSSL_DIR}"
}

main "$@"
