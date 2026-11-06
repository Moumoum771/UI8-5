
#!/usr/bin/env bash
#
# Firmware downloader and image extractor
# Models: SM-S926B and SM-A705FN
#
# Downloads TAR.MD5 packages, extracts their contents,
# and decompresses IMG.LZ4 files into IMG files.
#
# Output:
#   odin/MODEL_REGION/       Downloaded TAR.MD5 packages
#   firmware/MODEL_REGION/  Decompressed IMG files
#

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

ODIN_DIR="${ODIN_DIR:-$SCRIPT_DIR/odin}"
FW_OUTPUT_DIR="${FW_OUTPUT_DIR:-$SCRIPT_DIR/firmware}"

REGION="EUX"

# ============================================================
# DOWNLOAD LINKS
# ============================================================

S926_AP="https://01a1b026-dd10-70e0-93dc-8d70a5ec2057.sb05a.swisstransfer.infomaniak.cloud/01a1b0a2-6cea-7350-85c8-9f14e3753d29/01a1b0a2-6cef-71ab-92be-ab7268cf4e93?response-content-disposition=attachment%3B%20filename%3DAP_S926BXXSHDZI1_S926BXXSHDZI1_MQB115108131_REV00_user_low_ship_MULTI_CERT_meta_OS16.tar.md5&response-content-type=application%2Foctet-stream&X-Amz-Content-Sha256=UNSIGNED-PAYLOAD&X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=EE3ExaKl0oA6KOjaqihNThWEnNU7cJkR%2F20261106%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20261106T123340Z&X-Amz-SignedHeaders=host&X-Amz-Expires=3600&X-Amz-Signature=0590e9fddb94408dc7d250a8b940389a601848f9df57044352955311b1f701ba"
S926_CSC="https://ts.buzzheavier.com/d/ktgxz41l0nbt"

A705_AP="https://ts.buzzheavier.com/d/kj4r1visj0ke"
A705_BL="https://ts.buzzheavier.com/d/qgjjsxmubqw2"

# ============================================================
# ARGUMENTS
# ============================================================

FORCE=0

for arg in "$@"; do
    case "$arg" in
        --force|-f)
            FORCE=1
            ;;
        --help|-h)
            echo "Usage: $0 [--force]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"
            exit 1
            ;;
    esac
done

# ============================================================
# DEPENDENCIES
# ============================================================

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: Required command '$1' is not installed."
        exit 1
    fi
}

require_command curl
require_command tar
require_command lz4
require_command find
require_command mktemp
require_command cp

mkdir -p "$ODIN_DIR" "$FW_OUTPUT_DIR"

# ============================================================
# DOWNLOAD PACKAGE
# ============================================================

download_package() {
    local model="$1"
    local package="$2"
    local url="$3"
    local destination="$4"

    if [[ -z "$url" ]]; then
        echo "[SKIP] $model $package: no URL configured."
        return 0
    fi

    if [[ -s "$destination" && "$FORCE" -eq 0 ]]; then
        echo "[EXISTS] $(basename "$destination")"
        return 0
    fi

    echo
    echo "[DOWNLOAD] $model $package"
    echo "URL: $url"

    rm -f "$destination"

    curl \
        --fail \
        --location \
        --show-error \
        --retry 3 \
        --retry-delay 3 \
        --connect-timeout 30 \
        --output "$destination" \
        "$url"

    if [[ ! -s "$destination" ]]; then
        echo "ERROR: Downloaded file is empty: $destination"
        return 1
    fi

    echo "[OK] Downloaded $(basename "$destination")"
}

# ============================================================
# EXTRACT TAR.MD5 AND DECOMPRESS IMAGES
# ============================================================

extract_archive() {
    local model="$1"
    local archive="$2"
    local output_dir="$3"

    local archive_name
    archive_name="$(basename "$archive")"

    local temp_dir
    temp_dir="$(mktemp -d)"

    echo
    echo "[ARCHIVE] $archive_name"

    if ! tar -tf "$archive" >/dev/null 2>&1; then
        echo "ERROR: Cannot read TAR archive: $archive"
        rm -rf "$temp_dir"
        return 1
    fi

    if ! tar -xf "$archive" -C "$temp_dir"; then
        echo "ERROR: Failed to extract $archive_name"
        rm -rf "$temp_dir"
        return 1
    fi

    local extracted=0

    while IFS= read -r -d '' file; do
        local filename
        filename="$(basename "$file")"

        local output_name="$filename"
        local destination="$output_dir/$output_name"

        # Decompress IMG.LZ4, including super.img.lz4.
        if [[ "$filename" == *.img.lz4 ]]; then
            output_name="${filename%.lz4}"
            destination="$output_dir/$output_name"

            if [[ -e "$destination" ]]; then
                echo "[SKIP] $output_name already exists"
                continue
            fi

            echo "[LZ4] $filename -> $output_name"

            if ! lz4 -d -f "$file" "$destination"; then
                echo "ERROR: Failed to decompress $filename"
                rm -rf "$temp_dir"
                return 1
            fi

            ((extracted += 1))

        # Copy already decompressed IMG files.
        elif [[ "$filename" == *.img ]]; then
            if [[ -e "$destination" ]]; then
                echo "[SKIP] $output_name already exists"
                continue
            fi

            echo "[COPY] $filename"

            cp -f "$file" "$destination"

            ((extracted += 1))
        fi

    done < <(
        find "$temp_dir" -type f \
            \( -name "*.img.lz4" -o -name "*.img" \) \
            -print0
    )

    rm -rf "$temp_dir"

    echo "[OK] $archive_name: processed $extracted image(s)"
}

# ============================================================
# PROCESS MODEL
# ============================================================

process_model() {
    local model="$1"
    shift

    local model_odin="$ODIN_DIR/${model}_${REGION}"
    local model_firmware="$FW_OUTPUT_DIR/${model}_${REGION}"

    mkdir -p "$model_odin" "$model_firmware"

    if [[ "$FORCE" -eq 1 ]]; then
        echo "[FORCE] Removing previous firmware files for $model"

        rm -f "$model_odin"/*.tar.md5
        rm -f "$model_firmware"/*.img
        rm -f "$model_firmware"/.downloaded
    fi

    echo
    echo "=================================================="
    echo " MODEL: $model"
    echo "=================================================="

    local packages=("$@")

    local package
    local package_name
    local package_url
    local archive_path

    for package in "${packages[@]}"; do
        package_name="${package%%:*}"
        package_url="${package#*:}"

        archive_path="$model_odin/${model}_${package_name}.tar.md5"

        download_package \
            "$model" \
            "$package_name" \
            "$package_url" \
            "$archive_path"

        if [[ -s "$archive_path" ]]; then
            extract_archive \
                "$model" \
                "$archive_path" \
                "$model_firmware"
        fi
    done

    touch "$model_firmware/.downloaded"

    echo
    echo "[DONE] $model"
    echo "Firmware images: $model_firmware"
}

# ============================================================
# MAIN
# ============================================================

process_model "SM-S926B" \
    "AP:$S926_AP" \
    "CSC:$S926_CSC"

process_model "SM-A705FN" \
    "AP:$A705_AP" \
    "BL:$A705_BL"

echo
echo "=================================================="
echo " ALL DOWNLOADS AND EXTRACTIONS COMPLETED"
echo "=================================================="

echo
echo "Output directories:"
echo "  $FW_OUTPUT_DIR/SM-S926B_EUX"
echo "  $FW_OUTPUT_DIR/SM-A705FN_EUX"
