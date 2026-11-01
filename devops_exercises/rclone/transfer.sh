#!/usr/bin/env bash
# ==============================================================================
# Script: transfer.sh
# Purpose: Automated, configuration-free file transfer and synchronization
#          using Rclone for local and S3-compatible object storage (MinIO/AWS).
#
# Requirements fulfilled:
# - Supports 'copy', 'sync', and 'check' operations.
# - Displays real-time transfer progress.
# - Logs operations and errors to transfer.log with timestamps.
# - Returns exit code 0 on success, non-zero on error.
# - Configuration-free execution (no rclone.conf file required).
# ==============================================================================

set -eo pipefail

LOG_FILE="${TRANSFER_LOG_FILE:-transfer.log}"

main() {
    if [ $# -lt 3 ]; then
        usage
    fi

    local action="$1"
    local source="$2"
    local destination="$3"
    shift 3
    local extra_args=("$@")

    case "$action" in
        copy|move|sync|check)
            ;;
        *)
            log "ERROR" "Unknown action '$action'. Must be 'copy', 'move', 'sync', or 'check'."
            usage
            ;;
    esac

    # Ensure rclone is installed
    if ! command -v rclone &>/dev/null; then
        log "ERROR" "rclone command not found in PATH. Please install rclone."
        exit 127
    fi

    load_env "$source" "$destination"
    configure_rclone_environment

    log "INFO" "============================================================"
    log "INFO" "Starting transfer operation: $action"
    log "INFO" "Source:      $source"
    log "INFO" "Destination: $destination"
    if [ ${#extra_args[@]} -gt 0 ]; then
        log "INFO" "Options:     ${extra_args[*]}"
    fi

    local start_time=$(date +%s)
    local exit_code=0

    # Execute rclone with progress display, retries, and extra arguments
    # Explicitly disable reading/writing any static config file using --config=/dev/null
    if rclone "$action" "$source" "$destination" \
        --config=/dev/null \
        --progress \
        --retries 3 \
        --low-level-retries 10 \
        "${extra_args[@]}"; then
        local end_time=$(date +%s)
        local elapsed=$((end_time - start_time))
        log "SUCCESS" "Operation '$action' completed successfully in ${elapsed}s."
        exit_code=0
    else
        exit_code=$?
        local end_time=$(date +%s)
        local elapsed=$((end_time - start_time))
        log "ERROR" "Operation '$action' failed with exit code $exit_code after ${elapsed}s."
    fi

    log "INFO" "Finished at: $(date '+%Y-%m-%d %H:%M:%S')"
    log "INFO" "============================================================"
    return $exit_code
}


usage() {
    cat <<EOF
Usage: $0 <copy|move|sync|check> <source> <destination> [additional rclone options]

Operations:
  copy      Copy files from source to destination (skips identical, never deletes)
  move      Move files from source to destination (deletes source after verified transfer)
  sync      Make destination identical to source (WARNING: deletes destination files not in source!)
  check     Verify if source and destination match (read-only hash/size comparison)

Examples:
  # Local to local copy
  $0 copy ./test_data/source ./test_data/destination

  # Local to MinIO S3 sync (dry run first)
  $0 sync ./test_data/source myminio:exercise-bucket --dry-run

  # Local to MinIO S3 copy with bandwidth limit
  $0 copy ./test_data/test_file_1G.bin myminio:exercise-bucket/ --bwlimit 20M

Environment Variables (Optional, defaults auto-detected from .envs/.env):
  MINIO_ENDPOINT_URL       Endpoint for S3/MinIO (default: http://localhost:9000)
  MINIO_ACCESS_KEY_ID      S3 Access Key
  MINIO_SECRET_ACCESS_KEY  S3 Secret Key
  MINIO_REGION             S3 Region (default: us-east-1)
  TRANSFER_LOG_FILE        Path to log file (default: transfer.log)
EOF
    exit 1
}


log() {
    local level="$1"
    shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo -e "$msg" | tee -a "$LOG_FILE"
}

# Auto-load and validate environment variables exclusively from the local .env file
load_env() {
    local source="$1"
    local destination="$2"
    local is_s3=false

    if [[ "$source" =~ : ]] || [[ "$destination" =~ : ]]; then
        is_s3=true
    fi

    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local local_env="${script_dir}/.env"

    if [ ! -f "$local_env" ]; then
        if [ "$is_s3" = true ]; then
            log "ERROR" "Configuration error: Local .env file not found at '${local_env}'."
            log "ERROR" "Please create it using: cp .env.example .env and fill in your MinIO credentials."
            exit 1
        else
            return 0
        fi
    fi

    # Read variables strictly from the local .env file
    local endpoint="$(grep -E '^[[:space:]]*MINIO_ENDPOINT_URL=' "$local_env" | head -n 1 | cut -d '=' -f2- | tr -d '\r\n"'\'' ')"
    local access_key="$(grep -E '^[[:space:]]*MINIO_ACCESS_KEY_ID=' "$local_env" | head -n 1 | cut -d '=' -f2- | tr -d '\r\n"'\'' ')"
    local secret_key="$(grep -E '^[[:space:]]*MINIO_SECRET_ACCESS_KEY=' "$local_env" | head -n 1 | cut -d '=' -f2- | tr -d '\r\n"'\'' ')"
    local region="$(grep -E '^[[:space:]]*MINIO_REGION=' "$local_env" | head -n 1 | cut -d '=' -f2- | tr -d '\r\n"'\'' ')"

    export MINIO_ENDPOINT_URL="${MINIO_ENDPOINT_URL:-$endpoint}"
    export MINIO_ACCESS_KEY_ID="${MINIO_ACCESS_KEY_ID:-$access_key}"
    export MINIO_SECRET_ACCESS_KEY="${MINIO_SECRET_ACCESS_KEY:-$secret_key}"
    export MINIO_REGION="${MINIO_REGION:-${region:-us-east-1}}"

    # Validate that credentials are non-empty for S3 operations
    if [ "$is_s3" = true ]; then
        local missing_vars=()
        [ -z "$MINIO_ENDPOINT_URL" ] && missing_vars+=("MINIO_ENDPOINT_URL")
        [ -z "$MINIO_ACCESS_KEY_ID" ] && missing_vars+=("MINIO_ACCESS_KEY_ID")
        [ -z "$MINIO_SECRET_ACCESS_KEY" ] && missing_vars+=("MINIO_SECRET_ACCESS_KEY")

        if [ ${#missing_vars[@]} -gt 0 ]; then
            log "ERROR" "Invalid .env configuration: Missing required key(s): ${missing_vars[*]}"
            log "ERROR" "Please check '${local_env}' and supply all required MinIO credentials."
            exit 1
        fi
    fi
}

# Configure Rclone dynamically via process environment variables (Zero config file!)
configure_rclone_environment() {
    # Dynamically configure 'myminio' remote in memory without touching ~/.config/rclone/rclone.conf
    export RCLONE_CONFIG_MYMINIO_TYPE="s3"
    export RCLONE_CONFIG_MYMINIO_PROVIDER="Minio"
    export RCLONE_CONFIG_MYMINIO_ENDPOINT="$MINIO_ENDPOINT_URL"
    export RCLONE_CONFIG_MYMINIO_REGION="$MINIO_REGION"
    if [ -n "$MINIO_ACCESS_KEY_ID" ]; then
        export RCLONE_CONFIG_MYMINIO_ACCESS_KEY_ID="$MINIO_ACCESS_KEY_ID"
    fi
    if [ -n "$MINIO_SECRET_ACCESS_KEY" ]; then
        export RCLONE_CONFIG_MYMINIO_SECRET_ACCESS_KEY="$MINIO_SECRET_ACCESS_KEY"
    fi
}

main "$@"
