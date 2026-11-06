
#!/usr/bin/env bash
#
# Firmware filesystem extractor
# Compatible with download_fw.sh
#
# Supported devices:
#   SM-S926B
#   SM-A705FN
#
# Input:
#   firmware/SM-S926B_EUX/*.img
#   firmware/SM-A705FN_EUX/*.img
#
# Output:
#   extracted/SM-S926B_EUX/
#   extracted/SM-A705FN_EUX/
#

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

FW_INPUT_DIR="${1:-$SCRIPT_DIR/firmware}"
EXTRACT_OUTPUT_DIR="${2:-$SCRIPT_DIR/extracted}"

# ============================================================
# DEPENDENCIES
# ============================================================

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: Required command '$1' is not installed."
        exit 1
    fi
}

require_command find
require_command file
require_command mkdir
require_command cp

if ! command -v fsck.erofs >/dev/null 2>&1 &&
   ! command -v extract.erofs >/dev/null 2>&1; then
    echo "WARNING: Neither fsck.erofs nor extract.erofs is installed."
    echo "EROFS extraction will be unavailable."
fi

if ! command -v 7z >/dev/null 2>&1; then
    echo "WARNING: 7z is not installed."
    echo "EXT4 extraction will be unavailable."
fi

# ============================================================
# PARTITION NAME
# ============================================================

normalize_partition_name() {
    local name="$1"

    name="${name%.img}"
    name="${name%_a}"
    name="${name%_b}"

    printf '%s' "$name"
}

# ============================================================
# EROFS EXTRACTION
# ============================================================

extract_erofs() {
    local image="$1"
    local destination="$2"

    mkdir -p "$destination"

    if command -v fsck.erofs >/dev/null 2>&1; then
        fsck.erofs --extract="$destination" "$image"
        return $?
    fi

    if command -v extract.erofs >/dev/null 2>&1; then
        extract.erofs "$image" "$destination"
        return $?
    fi

    return 1
}

# ============================================================
# EXT4 EXTRACTION
# ============================================================

extract_ext4() {
    local image="$1"
    local destination="$2"

    mkdir -p "$destination"

    if ! command -v 7z >/dev/null 2>&1; then
        echo "[ERROR] 7z is required for EXT4 extraction."
        return 1
    fi

    7z x -y "-o$destination" "$image" >/dev/null
}

# ============================================================
# FILESYSTEM DETECTION AND EXTRACTION
# ============================================================

extract_filesystem() {
    local image="$1"
    local destination="$2"
    local partition="$3"

    local image_type

    image_type="$(file -b "$image" 2>/dev/null || true)"

    echo
    echo "=================================================="
    echo " PARTITION: $partition"
    echo "=================================================="

    echo "Image: $image"
    echo "Type:  $image_type"

    mkdir -p "$destination"

    if [[ "$image_type" == *EROFS* ]]; then

        echo "[EROFS] Extracting $partition"

        if ! extract_erofs "$image" "$destination"; then
            echo "[ERROR] EROFS extraction failed: $partition"
            return 1
        fi

    elif [[ "$image_type" == *ext4* ||
            "$image_type" == *"Linux rev 1.0 ext4"* ]]; then

        echo "[EXT4] Extracting $partition"

        if ! extract_ext4 "$image" "$destination"; then
            echo "[ERROR] EXT4 extraction failed: $partition"
            return 1
        fi

    elif [[ "$image_type" == *F2FS* ]]; then

        echo "[UNSUPPORTED] F2FS detected: $partition"
        echo "F2FS extraction is not implemented in this script."

    else

        echo "[SKIP] Unknown or unsupported filesystem: $partition"

    fi
}

# ============================================================
# SUPER.IMG EXTRACTION
# ============================================================

unpack_super() {
    local super_image="$1"
    local super_output="$2"

    local working_image="$super_image"
    local sparse_tmp=""

    mkdir -p "$super_output"

    local image_type
    image_type="$(file -b "$super_image" 2>/dev/null || true)"

    # Convert Android sparse image if necessary.
    if [[ "$image_type" == *"Android sparse image"* ]]; then

        if ! command -v simg2img >/dev/null 2>&1; then
            echo "[ERROR] super.img is sparse but simg2img is missing."
            return 1
        fi

        sparse_tmp="$super_output/super.raw.img"

        echo "[SUPER] Converting sparse image."

        if ! simg2img "$super_image" "$sparse_tmp"; then
            echo "[ERROR] simg2img failed."
            return 1
        fi

        working_image="$sparse_tmp"
    fi

    if ! command -v lpunpack >/dev/null 2>&1; then
        echo "[ERROR] lpunpack is required to unpack super.img."
        [[ -n "$sparse_tmp" ]] && rm -f "$sparse_tmp"
        return 1
    fi

    local partition_dir="$super_output/logical_images"

    mkdir -p "$partition_dir"

    echo
    echo "[SUPER] Unpacking logical partitions."

    if ! lpunpack "$working_image" "$partition_dir"; then
        echo "[ERROR] Failed to unpack super.img."
        [[ -n "$sparse_tmp" ]] && rm -f "$sparse_tmp"
        return 1
    fi

    [[ -n "$sparse_tmp" ]] && rm -f "$sparse_tmp"

    echo
    echo "[SUPER] Logical partitions found:"

    find "$partition_dir" -maxdepth 1 -type f -name "*.img" -printf '  %f\n'

    while IFS= read -r -d '' logical_image; do

        local filename
        filename="$(basename "$logical_image")"

        local partition
        partition="$(normalize_partition_name "$filename")"

        local destination="$super_output/$partition"

        extract_filesystem \
            "$logical_image" \
            "$destination" \
            "$partition"

        touch "$super_output/configs/file_context-$partition"
        touch "$super_output/configs/fs_config-$partition"

    done < <(
        find "$partition_dir" -maxdepth 1 -type f -name "*.img" -print0
    )
}

# ============================================================
# PROCESS FIRMWARE DIRECTORY
# ============================================================

process_firmware() {
    local firmware_dir="$1"

    local model_region
    model_region="$(basename "$firmware_dir")"

    local output_dir="$EXTRACT_OUTPUT_DIR/$model_region"

    echo
    echo "##################################################"
    echo " EXTRACTING FIRMWARE: $model_region"
    echo "##################################################"

    mkdir -p "$output_dir/configs"

    local image_count=0

    while IFS= read -r -d '' image; do

        ((image_count += 1))

        local filename
        filename="$(basename "$image")"

        local partition
        partition="$(normalize_partition_name "$filename")"

        if [[ "$filename" == "super.img" ]]; then

            echo
            echo "[SUPER] Found super.img"

            unpack_super "$image" "$output_dir/super"

            continue
        fi

        local destination="$output_dir/$partition"

        if [[ -d "$destination" ]] &&
           [[ -n "$(find "$destination" -mindepth 1 -print -quit)" ]]; then

            echo "[SKIP] $partition already extracted."
            continue
        fi

        extract_filesystem \
            "$image" \
            "$destination" \
            "$partition"

        touch "$output_dir/configs/file_context-$partition"
        touch "$output_dir/configs/fs_config-$partition"

    done < <(
        find "$firmware_dir" \
            -maxdepth 1 \
            -type f \
            -name "*.img" \
            -print0
    )

    if [[ "$image_count" -eq 0 ]]; then
        echo "[WARNING] No IMG files found in:"
        echo "$firmware_dir"
    fi

    echo
    echo "[DONE] $model_region"
    echo "Output: $output_dir"
}

# ============================================================
# MAIN
# ============================================================

if [[ ! -d "$FW_INPUT_DIR" ]]; then

    echo "ERROR: Firmware input directory does not exist:"
    echo "$FW_INPUT_DIR"

    exit 1
fi

mkdir -p "$EXTRACT_OUTPUT_DIR"

found_model=0

for model in SM-S926B_EUX SM-A705FN_EUX; do

    model_dir="$FW_INPUT_DIR/$model"

    if [[ -d "$model_dir" ]]; then

        found_model=1

        process_firmware "$model_dir"

    fi

done

if [[ "$found_model" -eq 0 ]]; then

    echo "ERROR: No supported firmware directories found."

    echo "Expected:"
    echo "  $FW_INPUT_DIR/SM-S926B_EUX"
    echo "  $FW_INPUT_DIR/SM-A705FN_EUX"

    exit 1
fi

echo
echo "##################################################"
echo " ALL FIRMWARE EXTRACTION COMPLETED"
echo "##################################################"

echo
echo "Output:"
echo "  $EXTRACT_OUTPUT_DIR/SM-S926B_EUX"
echo "  $EXTRACT_OUTPUT_DIR/SM-A705FN_EUX"
