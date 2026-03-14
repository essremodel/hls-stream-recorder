#!/usr/bin/env bash

CHANNELS_CONF_PATH_DEFAULT="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/channels.conf"
CUSTOM_STREAMS_PATH_DEFAULT="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/streams.txt"

declare -a CHANNEL_CATEGORIES=()
declare -a CHANNEL_SHORTS=()
declare -a CHANNEL_NAMES=()
declare -a CHANNEL_URLS=()
declare -a CHANNEL_NOTES=()
declare -a CHANNEL_SOURCES=()
declare -A CHANNEL_INDEX_BY_SHORT=()

channels_trim_ws() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

channels_normalize_short_name() {
    local value
    value=$(channels_trim_ws "$1")
    printf '%s' "$value" | tr '[:upper:]' '[:lower:]'
}

channels_reset() {
    CHANNEL_CATEGORIES=()
    CHANNEL_SHORTS=()
    CHANNEL_NAMES=()
    CHANNEL_URLS=()
    CHANNEL_NOTES=()
    CHANNEL_SOURCES=()
    CHANNEL_INDEX_BY_SHORT=()
}

channels_load_file() {
    local source_name="$1"
    local file_path="$2"
    local line category short_name short_key display_name url notes index

    [ -f "$file_path" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "${line//[[:space:]]/}" ] || continue
        case "$line" in
            \#*) continue ;;
        esac

        IFS='|' read -r category short_name display_name url notes <<< "$line"
        category=$(channels_trim_ws "$category")
        short_name=$(channels_trim_ws "$short_name")
        short_key=$(channels_normalize_short_name "$short_name")
        display_name=$(channels_trim_ws "$display_name")
        url=$(channels_trim_ws "$url")
        notes=$(channels_trim_ws "$notes")
        if [ -z "$category" ] || [ -z "$short_name" ] || [ -z "$display_name" ] || [ -z "$url" ]; then
            printf 'Invalid channel entry in %s: %s\n' "$file_path" "$line" >&2
            return 1
        fi
        if [ -n "${CHANNEL_INDEX_BY_SHORT[$short_key]:-}" ]; then
            printf 'Duplicate stream short name "%s" in %s\n' "$short_name" "$file_path" >&2
            return 1
        fi

        CHANNEL_CATEGORIES+=("$category")
        CHANNEL_SHORTS+=("$short_key")
        CHANNEL_NAMES+=("$display_name")
        CHANNEL_URLS+=("$url")
        CHANNEL_NOTES+=("$notes")
        CHANNEL_SOURCES+=("$source_name")
        index=$((${#CHANNEL_SHORTS[@]} - 1))
        CHANNEL_INDEX_BY_SHORT["$short_key"]="$index"
    done < "$file_path"
}

channels_load_catalog() {
    local built_in_path="${1:-$CHANNELS_CONF_PATH_DEFAULT}"
    local custom_path="${2:-$CUSTOM_STREAMS_PATH_DEFAULT}"

    channels_reset
    channels_load_file "built-in" "$built_in_path" || return 1
    channels_load_file "custom" "$custom_path" || return 1

    if [ "${#CHANNEL_SHORTS[@]}" -eq 0 ]; then
        printf 'No channels loaded from %s\n' "$built_in_path" >&2
        return 1
    fi
}
