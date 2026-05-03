#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
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
    require_command cp

    log "Preparing temporary download directory..."
    mkdir -p "${TMP_ROOT}"
    safe_remove_dir "${DL_DIR}"
    mkdir -p "${DL_DIR}"

    cd "${DL_DIR}"

    log "Fetching OpenSSL source page..."
    PAGE="$(curl -fsSL --retry 3 --retry-all-errors "${SOURCE_URL}")"

    DOWNLOAD_URL="$(
        printf '%s\n' "${PAGE}" \
            | awk '
                /\[LTS\]/,/<\/tr>/ {
                    if (match($0, /https:\/\/github\.com\/openssl\/openssl\/releases\/download\/[^"]+\.tar\.gz/)) {
                        print substr($0, RSTART, RLENGTH)
                        exit
                    }
                }
            '
    )"

    [[ -n "${DOWNLOAD_URL}" ]] || die "Failed to find the latest LTS OpenSSL tarball URL."

    FILENAME="$(basename -- "${DOWNLOAD_URL}")"
    [[ -n "${FILENAME}" ]] || die "Could not determine tarball filename."

    log "Downloading OpenSSL LTS from: ${DOWNLOAD_URL}"
    curl -fL --retry 3 --retry-all-errors -o "${FILENAME}" "${DOWNLOAD_URL}"

    [[ -s "${FILENAME}" ]] || die "Downloaded tarball is missing or empty: ${FILENAME}"

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
