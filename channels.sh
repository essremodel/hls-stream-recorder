#!/usr/bin/env bash

CHANNELS_CONF_PATH_DEFAULT="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/channels.conf"
CUSTOM_STREAMS_PATH_DEFAULT="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/streams.txt"

declare -a CHANNEL_CATEGORIES=()
declare -a CHANNEL_CATEGORY_ORDER=()
declare -a CHANNEL_SHORTS=()
declare -a CHANNEL_NAMES=()
declare -a CHANNEL_URLS=()
declare -a CHANNEL_NOTES=()
declare -a CHANNEL_NOTE_TOKENS=()
declare -a CHANNEL_SOURCES=()
declare -A CHANNEL_CATEGORY_COUNTS=()
declare -A CHANNEL_INDEX_BY_SHORT=()

channels_reset() {
    CHANNEL_CATEGORIES=()
    CHANNEL_CATEGORY_ORDER=()
    CHANNEL_SHORTS=()
    CHANNEL_NAMES=()
    CHANNEL_URLS=()
    CHANNEL_NOTES=()
    CHANNEL_SOURCES=()
    CHANNEL_CATEGORY_COUNTS=()
    CHANNEL_INDEX_BY_SHORT=()
}

channels_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

channels_short_key() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

channels_split_notes() {
    local notes="$1"
    local current=""
    local quote=""
    local char
    local idx

    CHANNEL_NOTE_TOKENS=()

    for (( idx=0; idx<${#notes}; idx++ )); do
        char="${notes:idx:1}"

        if [ -n "$quote" ]; then
            if [ "$char" = "\\" ] && [ $((idx + 1)) -lt ${#notes} ]; then
                idx=$((idx + 1))
                current+="${notes:idx:1}"
            elif [ "$char" = "$quote" ]; then
                quote=""
            else
                current+="$char"
            fi
            continue
        fi

        case "$char" in
            ';')
                current="$(channels_trim "$current")"
                [ -n "$current" ] && CHANNEL_NOTE_TOKENS+=("$current")
                current=""
                ;;
            '"')
                quote='"'
                ;;
            "'")
                quote="'"
                ;;
            '\\')
                if [ $((idx + 1)) -lt ${#notes} ]; then
                    idx=$((idx + 1))
                    current+="${notes:idx:1}"
                fi
                ;;
            *)
                current+="$char"
                ;;
        esac
    done

    current="$(channels_trim "$current")"
    [ -n "$current" ] && CHANNEL_NOTE_TOKENS+=("$current")
}

channels_user_agent_from_notes() {
    local notes="$1"
    local token
    local ua_value

    channels_split_notes "$notes"
    for token in "${CHANNEL_NOTE_TOKENS[@]}"; do
        case "$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]')" in
            ua=*|user-agent=*)
                ua_value="$(channels_trim "${token#*=}")"
                [ -n "$ua_value" ] || return 1
                printf '%s' "$ua_value"
                return 0
                ;;
        esac
    done
    return 1
}

channels_notes_display() {
    local notes="$1"
    local cleaned=()
    local token
    local idx
    channels_split_notes "$notes"
    for token in "${CHANNEL_NOTE_TOKENS[@]}"; do
        case "$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]')" in
            ua=*|user-agent=*)
                ;;
            *)
                [ -n "$token" ] && cleaned+=("$token")
                ;;
        esac
    done

    if [ "${#cleaned[@]}" -eq 0 ]; then
        return 1
    fi

    printf '%s' "${cleaned[0]}"
    for (( idx=1; idx<${#cleaned[@]}; idx++ )); do
        printf '; %s' "${cleaned[$idx]}"
    done
}

channels_load_file() {
    local source_name="$1"
    local file_path="$2"
    local line category short_name display_name url notes index short_key

    [ -f "$file_path" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "${line//[[:space:]]/}" ] || continue
        case "$line" in
            \#*) continue ;;
        esac

        IFS='|' read -r category short_name display_name url notes <<< "$line"
        category="$(channels_trim "$category")"
        short_name="$(channels_trim "$short_name")"
        display_name="$(channels_trim "$display_name")"
        url="$(channels_trim "$url")"
        notes="$(channels_trim "$notes")"
        if [ -z "$category" ] || [ -z "$short_name" ] || [ -z "$display_name" ] || [ -z "$url" ]; then
            printf 'Invalid channel entry in %s: %s\n' "$file_path" "$line" >&2
            return 1
        fi
        short_key="$(channels_short_key "$short_name")"
        if [ -n "${CHANNEL_INDEX_BY_SHORT[$short_key]:-}" ]; then
            printf 'Duplicate stream short name "%s" in %s\n' "$short_name" "$file_path" >&2
            return 1
        fi

        if [ -z "${CHANNEL_CATEGORY_COUNTS[$category]:-}" ]; then
            CHANNEL_CATEGORY_ORDER+=("$category")
            CHANNEL_CATEGORY_COUNTS["$category"]=0
        fi

        CHANNEL_CATEGORIES+=("$category")
        CHANNEL_SHORTS+=("$short_key")
        CHANNEL_NAMES+=("$display_name")
        CHANNEL_URLS+=("$url")
        CHANNEL_NOTES+=("$notes")
        CHANNEL_SOURCES+=("$source_name")
        index=$((${#CHANNEL_SHORTS[@]} - 1))
        CHANNEL_INDEX_BY_SHORT["$short_key"]="$index"
        CHANNEL_CATEGORY_COUNTS["$category"]=$((CHANNEL_CATEGORY_COUNTS["$category"] + 1))
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
