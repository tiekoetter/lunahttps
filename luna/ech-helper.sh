#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly DEFAULT_CONFIG_DIR="/etc/nginx/sites-enabled"
readonly DEFAULT_KEY_DIR="/etc/nginx/ech"
readonly DEFAULT_NGINX_BIN="/usr/sbin/nginx"
# OpenSSL CLI that the NGINX build leaves behind after build.sh has run.
readonly BUILD_OPENSSL_BIN="${SCRIPT_DIR}/openssl/.openssl/bin/openssl"
readonly DROP_IN_NAME="luna-ech.conf"
readonly KEY_NAME="ech.pem"
readonly PREVIOUS_KEY_NAME="ech-previous.pem"

CONFIG_DIR=""
KEY_DIR="${DEFAULT_KEY_DIR}"
PUBLIC_NAME=""
OPENSSL_BIN=""
NGINX_BIN=""
ROTATE=0
RELOAD=1

STAGING_DIR=""
ROLLBACK_NEEDED=0
__error_reported=0

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
    __error_reported=1
    printf '%b\n' "${RED}Error: $*${NC}" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $0 [options] [CONFIG_DIR]

Enables TLS Encrypted ClientHello (ECH) for all server blocks by writing one
http-level drop-in file (${DROP_IN_NAME}) into CONFIG_DIR. Existing files in
CONFIG_DIR are not edited, and the directory is backed up before it changes.

Run it again at any time: it only changes what is missing. Use --rotate to
replace the key; the current key is kept as the previous key so that clients
holding the old DNS record keep working.

Arguments:
  CONFIG_DIR          Directory NGINX includes inside its http block
                      (default: ${DEFAULT_CONFIG_DIR})

Options:
  --public-name NAME  Hostname sent in the visible outer ClientHello. Required
                      when the first key is generated, reused afterwards.
  --rotate            Generate a new key and keep the current one as previous.
  --key-dir DIR       Directory for the ECH keys (default: ${DEFAULT_KEY_DIR})
  --openssl PATH      OpenSSL 4.0+ binary (default: the one built by build.sh,
                      then "openssl" from PATH)
  --nginx PATH        NGINX binary (default: ${DEFAULT_NGINX_BIN}, then PATH)
  --no-reload         Validate the configuration, but do not reload NGINX.
  -h, --help          Show this help.
EOF
}

report_error() {
    local exit_code=$1
    local line_no=$2

    if [[ $__error_reported -eq 0 ]]; then
        __error_reported=1
        printf '%b\n' "${RED}ECH helper failed (exit code ${exit_code}) near line ${line_no}.${NC}" >&2
    fi

    exit "${exit_code}"
}

restore_file() {
    local saved="$1"
    local target="$2"

    if [[ -f "${saved}" ]]; then
        cp -p -- "${saved}" "${target}" || warn "Could not restore ${target}"
    else
        rm -f -- "${target}" || warn "Could not remove ${target}"
    fi
}

finish() {
    local exit_code=$?

    trap - EXIT ERR
    set +e

    if [[ ${ROLLBACK_NEEDED} -eq 1 ]]; then
        printf '%b\n' "${YELLOW}Restoring the previous ECH keys and ${DROP_IN_NAME}...${NC}" >&2
        restore_file "${STAGING_DIR}/saved/${KEY_NAME}" "${KEY_DIR}/${KEY_NAME}"
        restore_file "${STAGING_DIR}/saved/${PREVIOUS_KEY_NAME}" "${KEY_DIR}/${PREVIOUS_KEY_NAME}"
        restore_file "${STAGING_DIR}/saved/${DROP_IN_NAME}" "${CONFIG_DIR}/${DROP_IN_NAME}"
    fi

    if [[ -n "${STAGING_DIR}" && -d "${STAGING_DIR}" ]]; then
        rm -rf -- "${STAGING_DIR}"
    fi

    exit "${exit_code}"
}

trap 'report_error $? $LINENO' ERR
trap finish EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --public-name|--key-dir|--openssl|--nginx)
                [[ $# -ge 2 ]] || die "Option $1 requires a value."
                case "$1" in
                    --public-name) PUBLIC_NAME="$2" ;;
                    --key-dir)     KEY_DIR="$2" ;;
                    --openssl)     OPENSSL_BIN="$2" ;;
                    --nginx)       NGINX_BIN="$2" ;;
                esac
                shift
                ;;
            --rotate)
                ROTATE=1
                ;;
            --no-reload)
                RELOAD=0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                [[ -z "${CONFIG_DIR}" ]] || die "Only one CONFIG_DIR can be given."
                CONFIG_DIR="$1"
                ;;
        esac
        shift
    done

    [[ -n "${CONFIG_DIR}" ]] || CONFIG_DIR="${DEFAULT_CONFIG_DIR}"
}

# Paths are written unquoted into the NGINX configuration.
require_conf_safe_path() {
    [[ "$1" =~ ^/[A-Za-z0-9._/@+-]+$ ]] || \
        die "Path contains characters that are not safe in an NGINX configuration: $1"
}

validate_public_name() {
    [[ ${#PUBLIC_NAME} -le 253 && "${PUBLIC_NAME}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || \
        die "Invalid public name: ${PUBLIC_NAME}"
}

resolve_directories() {
    [[ -d "${CONFIG_DIR}" ]] || die "Configuration directory not found: ${CONFIG_DIR}"
    CONFIG_DIR="$(cd -- "${CONFIG_DIR}" && pwd -P)"
    [[ "${CONFIG_DIR}" != "/" ]] || die "Refusing to use / as configuration directory."
    [[ -w "${CONFIG_DIR}" ]] || die "Configuration directory is not writable: ${CONFIG_DIR}"

    mkdir -p -- "${KEY_DIR}"
    KEY_DIR="$(cd -- "${KEY_DIR}" && pwd -P)"
    [[ -w "${KEY_DIR}" ]] || die "Key directory is not writable: ${KEY_DIR}"
    [[ "${KEY_DIR}" != "${CONFIG_DIR}" ]] || die "The key directory must differ from the configuration directory."
    chmod 700 "${KEY_DIR}"

    require_conf_safe_path "${KEY_DIR}"
}

# The exit code is not enough: LibreSSL returns 0 for unknown commands.
supports_ech() {
    "$1" ech -help 2>&1 | grep -q -- '-public_name'
}

find_openssl() {
    if [[ -n "${OPENSSL_BIN}" ]]; then
        supports_ech "${OPENSSL_BIN}" || \
            die "${OPENSSL_BIN} has no \"ech\" command. OpenSSL 4.0 or newer is required."
        return
    fi

    if [[ -x "${BUILD_OPENSSL_BIN}" ]] && supports_ech "${BUILD_OPENSSL_BIN}"; then
        OPENSSL_BIN="${BUILD_OPENSSL_BIN}"
    elif command -v openssl >/dev/null 2>&1 && supports_ech openssl; then
        OPENSSL_BIN="openssl"
    else
        die "No OpenSSL binary with the \"ech\" command found (OpenSSL 4.0 or newer). Run build.sh first or pass --openssl PATH."
    fi
}

find_nginx() {
    if [[ -z "${NGINX_BIN}" ]]; then
        if [[ -x "${DEFAULT_NGINX_BIN}" ]]; then
            NGINX_BIN="${DEFAULT_NGINX_BIN}"
        else
            NGINX_BIN="$(command -v nginx || true)"
        fi
    fi

    [[ -n "${NGINX_BIN}" ]] || die "NGINX binary not found. Pass --nginx PATH."
    "${NGINX_BIN}" -v >/dev/null 2>&1 || die "Cannot run NGINX binary: ${NGINX_BIN}"
}

key_public_name() {
    "${OPENSSL_BIN}" ech -in "$1" -text 2>&1 | \
        awk '!found { for (i = 1; i < NF; i++) if ($i == "public_name:") { print $(i + 1); found = 1; break } }'
}

key_config_list() {
    awk '/^-----BEGIN ECHCONFIG-----/ { inside = 1; next }
         /^-----END ECHCONFIG-----/   { inside = 0 }
         inside                       { printf "%s", $0 }' "$1"
}

generate_key() {
    local out="$1"

    "${OPENSSL_BIN}" ech -public_name "${PUBLIC_NAME}" -out "${out}"

    grep -q -- '-----BEGIN PRIVATE KEY-----' "${out}" && [[ -n "$(key_config_list "${out}")" ]] || \
        die "OpenSSL did not produce a usable ECH key file."
}

write_drop_in() {
    local out="$1"
    local with_previous="$2"

    {
        printf '%s\n' "# Managed by Luna-HTTP/S luna/ech-helper.sh; manual changes are overwritten."
        printf '%s\n' "# Only the first key is offered to clients whose key is outdated. A second"
        printf '%s\n' "# line, if present, is the previous key."
        printf '%s\n' "ssl_ech_file ${KEY_DIR}/${KEY_NAME};"
        if [[ "${with_previous}" -eq 1 ]]; then
            printf '%s\n' "ssl_ech_file ${KEY_DIR}/${PREVIOUS_KEY_NAME};"
        fi
    } > "${out}"
}

backup_config_dir() {
    local parent
    local base
    local archive

    parent="$(dirname -- "${CONFIG_DIR}")"
    base="$(basename -- "${CONFIG_DIR}")"
    # Kept outside CONFIG_DIR so that a wildcard include never loads it.
    archive="${parent}/${base}.ech-backup-$(date +%Y%m%d-%H%M%S).tar.gz"

    [[ -w "${parent}" ]] || die "Cannot write the backup to ${parent}."
    [[ ! -e "${archive}" ]] || die "Backup already exists: ${archive}"

    tar -czf "${archive}" -C "${parent}" "./${base}"
    log "Backed up ${CONFIG_DIR} to ${archive}"
}

save_for_rollback() {
    local file

    mkdir -- "${STAGING_DIR}/saved"

    for file in "${KEY_DIR}/${KEY_NAME}" "${KEY_DIR}/${PREVIOUS_KEY_NAME}" "${CONFIG_DIR}/${DROP_IN_NAME}"; do
        if [[ -f "${file}" ]]; then
            cp -p -- "${file}" "${STAGING_DIR}/saved/"
        fi
    done
}

check_existing_configuration() {
    if ! "${NGINX_BIN}" -t > "${STAGING_DIR}/nginx-before.log" 2>&1; then
        cat "${STAGING_DIR}/nginx-before.log" >&2
        die "The current NGINX configuration is not valid. Nothing was changed."
    fi
}

# NGINX prints included paths as written in its configuration, which may go
# through symlinks, so files are compared by identity rather than by name.
drop_in_is_loaded() {
    local dump="$1"
    local path

    while IFS= read -r path; do
        if [[ "${path}" -ef "${CONFIG_DIR}/${DROP_IN_NAME}" ]]; then
            return 0
        fi
    done < <(awk -v suffix="/${DROP_IN_NAME}:" '
        index($0, "# configuration file ") == 1 &&
        substr($0, length($0) - length(suffix) + 1) == suffix {
            print substr($0, 22, length($0) - 22)
        }' "${dump}")

    return 1
}

validate_new_configuration() {
    local dump="${STAGING_DIR}/nginx-after.log"

    if ! "${NGINX_BIN}" -T > "${dump}" 2>&1; then
        grep -E '^nginx: ' "${dump}" >&2 || true
        die "NGINX rejected the configuration with ECH enabled."
    fi

    if grep -qF 'ssl_ech_file" is not supported' "${dump}"; then
        die "This NGINX binary was built without ECH support (OpenSSL 4.0 or newer is required)."
    fi

    drop_in_is_loaded "${dump}" || \
        die "NGINX does not load ${CONFIG_DIR}/${DROP_IN_NAME}. Point this script at a directory that is included inside the http block."

    if ! awk -v name="${PUBLIC_NAME}" '
        BEGIN { name = tolower(name) }
        /^[ \t]*#/ { next }
        {
            for (i = 1; i <= NF; i++) {
                token = $i
                if (!listing) {
                    if (token == "server_name") listing = 1
                    continue
                }
                last = (token ~ /;/)
                sub(/;.*$/, "", token)
                if (tolower(token) == name) found = 1
                if (last) listing = 0
            }
        }
        END { exit !found }' "${dump}"; then
        warn "No server_name matches the public name ${PUBLIC_NAME}. Clients fall back to that name when ECH fails, so a server block with a valid certificate for it should exist."
    fi
}

reload_nginx() {
    if [[ ${RELOAD} -eq 0 ]]; then
        warn "NGINX was not reloaded (--no-reload). Reload it to apply the change."
        return
    fi

    "${NGINX_BIN}" -s reload || \
        die "The configuration is valid and in place, but reloading NGINX failed. Reload it manually."
    log "Reloaded NGINX."
}

print_summary() {
    local config_list

    config_list="$(key_config_list "${KEY_DIR}/${KEY_NAME}")"

    printf '\n%b\n' "${GREEN}ECH is configured.${NC}"
    cat <<EOF

  Drop-in file:   ${CONFIG_DIR}/${DROP_IN_NAME}
  Key directory:  ${KEY_DIR}
  Public name:    ${PUBLIC_NAME}
  ECHConfigList:  ${config_list}

Clients only use ECH once the ECHConfigList is published in the HTTPS DNS
record of every protected hostname, for example:

  example.com. 300 IN HTTPS 1 . alpn="h3,h2" ech="${config_list}"
EOF
}

main() {
    local current_key
    local previous_key
    local drop_in
    local existing_public_name=""
    local generate=0
    local with_previous=0
    local drop_in_changed=0

    parse_args "$@"

    require_command awk
    require_command tar
    require_command mktemp
    require_command cmp
    require_command date

    resolve_directories
    find_openssl
    find_nginx

    current_key="${KEY_DIR}/${KEY_NAME}"
    previous_key="${KEY_DIR}/${PREVIOUS_KEY_NAME}"
    drop_in="${CONFIG_DIR}/${DROP_IN_NAME}"

    STAGING_DIR="$(mktemp -d "${KEY_DIR}/.ech-helper.XXXXXX")"

    if [[ -f "${current_key}" ]]; then
        existing_public_name="$(key_public_name "${current_key}")"
        [[ -n "${existing_public_name}" ]] || die "Cannot read the public name from ${current_key}."
    fi

    if [[ -z "${existing_public_name}" ]]; then
        [[ -n "${PUBLIC_NAME}" ]] || die "--public-name is required to generate the first ECH key."
        generate=1
    elif [[ ${ROTATE} -eq 1 ]]; then
        [[ -n "${PUBLIC_NAME}" ]] || PUBLIC_NAME="${existing_public_name}"
        generate=1
    elif [[ -n "${PUBLIC_NAME}" && "${PUBLIC_NAME}" != "${existing_public_name}" ]]; then
        die "The current key uses the public name ${existing_public_name}. Add --rotate to switch to ${PUBLIC_NAME}."
    else
        PUBLIC_NAME="${existing_public_name}"
    fi

    validate_public_name

    if [[ -f "${previous_key}" ]] || [[ ${generate} -eq 1 && -f "${current_key}" ]]; then
        with_previous=1
    fi

    write_drop_in "${STAGING_DIR}/${DROP_IN_NAME}" "${with_previous}"
    cmp -s "${STAGING_DIR}/${DROP_IN_NAME}" "${drop_in}" || drop_in_changed=1

    if [[ ${generate} -eq 0 && ${drop_in_changed} -eq 0 ]]; then
        log "ECH is already set up; nothing to change. Use --rotate to replace the key."
        print_summary
        return
    fi

    check_existing_configuration

    if [[ ${generate} -eq 1 ]]; then
        log "Generating a new ECH key for ${PUBLIC_NAME}..."
        generate_key "${STAGING_DIR}/${KEY_NAME}"
    fi

    if [[ ${drop_in_changed} -eq 1 ]]; then
        backup_config_dir
    fi

    save_for_rollback
    ROLLBACK_NEEDED=1

    if [[ ${generate} -eq 1 ]]; then
        if [[ -f "${current_key}" ]]; then
            mv -f -- "${current_key}" "${previous_key}"
        fi
        mv -f -- "${STAGING_DIR}/${KEY_NAME}" "${current_key}"
        chmod 600 "${current_key}"
    fi

    if [[ ${drop_in_changed} -eq 1 ]]; then
        cp -- "${STAGING_DIR}/${DROP_IN_NAME}" "${drop_in}"
        chmod 644 "${drop_in}"
    fi

    log "Validating the NGINX configuration..."
    validate_new_configuration
    ROLLBACK_NEEDED=0

    reload_nginx
    print_summary

    if [[ ${generate} -eq 1 && ${with_previous} -eq 1 ]]; then
        printf '\n%s\n' "The key was rotated: update the DNS records now. The previous key stays valid until the next rotation."
    fi
}

main "$@"
