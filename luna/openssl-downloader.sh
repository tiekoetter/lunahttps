#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly WORK_DIR="${SCRIPT_DIR}"
readonly OPENSSL_DIR="${WORK_DIR}/openssl-lts"
readonly TMP_ROOT="${WORK_DIR}/.tmp"
readonly DL_DIR="${TMP_ROOT}/openssl-download"
readonly SOURCE_URL="https://openssl-library.org/source/"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[1;34m'
NC=$'\033[0m'

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
    local exit_code=$?
    printf '%b\n' "${RED}OpenSSL downloader failed (exit code ${exit_code}) near line ${BASH_LINENO[0]:-unknown}.${NC}" >&2
    exit "${exit_code}"
}

trap cleanup_on_error ERR

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

safe_remove_dir() {
    local dir="$1"
    [[ -n "$dir" ]] || die "Refusing to remove empty path"
    [[ "$dir" != "/" ]] || die "Refusing to remove /"
    rm -rf -- "$dir"
}

main() {
    require_command curl
    require_command awk
    require_command grep
    require_command tar
    require_command basename
    require_command mktemp
    require_command mv

    log "Preparing temporary download directory..."
    mkdir -p "${TMP_ROOT}"
    safe_remove_dir "${DL_DIR}"
    mkdir -p "${DL_DIR}"

    cd "${DL_DIR}"

    log "Fetching OpenSSL source page..."
    PAGE="$(curl -fsSL --retry 3 --retry-all-errors "${SOURCE_URL}")"

    DOWNLOAD_URL="$(
        printf '%s\n' "${PAGE}" \
            | awk '/\[LTS\]/,/<\/tr>/' \
            | grep -oE 'https://github\.com/openssl/openssl/releases/download/[^"]+\.tar\.gz' \
            | head -n1
    )"

    [[ -n "${DOWNLOAD_URL}" ]] || die "Failed to find the latest LTS OpenSSL tarball URL."

    FILENAME="$(basename -- "${DOWNLOAD_URL}")"
    [[ -n "${FILENAME}" ]] || die "Could not determine tarball filename."

    log "Downloading OpenSSL LTS from: ${DOWNLOAD_URL}"
    curl -fL --retry 3 --retry-all-errors -o "${FILENAME}" "${DOWNLOAD_URL}"

    [[ -s "${FILENAME}" ]] || die "Downloaded tarball is missing or empty: ${FILENAME}"

    log "Extracting ${FILENAME}..."
    tar -xzf "${FILENAME}"

    EXTRACTED_DIR="$(
        tar -tf "${FILENAME}" \
            | head -n1 \
            | cut -d/ -f1
    )"

    [[ -n "${EXTRACTED_DIR}" ]] || die "Could not determine extracted directory name."
    [[ -d "${DL_DIR}/${EXTRACTED_DIR}" ]] || die "Extracted directory not found: ${DL_DIR}/${EXTRACTED_DIR}"

    case "${EXTRACTED_DIR}" in
        openssl-*)
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
