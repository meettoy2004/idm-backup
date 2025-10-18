#!/bin/bash
IFS=$'\n\t'

IPA_BACKUP_DIR="/var/lib/ipa/backup"
S3_MOUNT_DIR="/mnt/idm-backup"
KEEP_COUNT=10

log() {
    printf "%s - %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

validate_backup() {
    local backup_file sha_file
    backup_file="${1}"
    sha_file="${backup_file}.sha256"

    if [[ -f "${sha_file}" && -f "${backup_file}" ]]; then
        log "Validating SHA256 for: $(basename "${backup_file}")"
        if cd "$(dirname "${backup_file}")" && sha256sum -c "$(basename "${sha_file}")" >/dev/null 2>&1; then
            log "✓ SHA256 validation passed: $(basename "${backup_file}")"
            return
        fi
        printf "✗ SHA256 validation failed: %s\n" "$(basename "${backup_file}")" >&2
        return 1
    fi

    printf "⚠ SHA256 file missing for: %s\n" "$(basename "${backup_file}")" >&2
    return 1
}

find_backup_archives_by_name_timestamp() {
    local directory pattern
    directory="${1}"
    pattern="${2}"

    find "${directory}" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) -name "${pattern}" 2>/dev/null |
    while read -r path; do
        local name ts
        name=$(basename "${path}")
        
        # Match and extract timestamp based on known formats
        if [[ "${name}" =~ ipa-full-([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2})$ ]]; then
            ts="${BASH_REMATCH[1]}"
        elif [[ "${name}" =~ ipa-([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2})\.tar\.gz\.gpg$ ]]; then
            ts="${BASH_REMATCH[1]}-00"
        else
            continue
        fi

        ts="${ts//-/}" # remove dashes
        printf "%s %s\n" "${ts}" "${path}"
    done | sort -rk1 | awk '{$1=""; sub(/^ /,""); print}'
}

cleanup_directory() {
    local dir pattern desc
    dir="${1}"
    pattern="${2}"
    desc="${3}"

    if [[ ! -d "${dir}" ]]; then
        printf "Directory not found: %s\n" "${dir}" >&2
        return 1
    fi

    log "Cleaning up ${desc} (keeping latest ${KEEP_COUNT})"

    local files=()
    if ! mapfile -t files < <(find_backup_archives_by_name_timestamp "${dir}" "${pattern}"); then
        printf "Failed to enumerate backups in: %s\n" "${dir}" >&2
        return 1
    fi

    if [[ ${#files[@]} -le ${KEEP_COUNT} ]]; then
        log "No cleanup needed - only ${#files[@]} ${desc} found"
        return
    fi

    local last_keep
    last_keep="${files[$((KEEP_COUNT - 1))]}"

    if [[ -f "${last_keep}" ]]; then
        if ! validate_backup "${last_keep}"; then
            printf "✗ Aborting cleanup - validation failed for backup that would be kept: %s\n" "$(basename "${last_keep}")" >&2
            return 1
        fi
    fi

    for ((i=KEEP_COUNT; i<${#files[@]}; i++)); do
        local file_to_delete sha_file
        file_to_delete="${files[${i}]}"
        sha_file="${file_to_delete}.sha256"

        log "Removing: $(basename "${file_to_delete}")"
        rm -rf -- "${file_to_delete}"
        [[ -f "${sha_file}" ]] && rm -f -- "${sha_file}"
    done

    log "Cleanup completed for ${desc} - removed $((${#files[@]} - KEEP_COUNT)) old backups"
}

main() {
    log "Starting IPA backup cleanup"

    if ! cleanup_directory "${S3_MOUNT_DIR}" "ipa-*.tar.gz.gpg" "encrypted backups"; then
        printf "Failed to clean up encrypted backups in %s\n" "${S3_MOUNT_DIR}" >&2
        return 1
    fi

    if ! cleanup_directory "${IPA_BACKUP_DIR}" "ipa-full-*" "original IPA backups"; then
        printf "Failed to clean up original IPA backups in %s\n" "${IPA_BACKUP_DIR}" >&2
        return 1
    fi

    log "IPA backup cleanup completed successfully"
}

main "$@" || exit $?