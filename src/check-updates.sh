#!/bin/bash
#
# Check for Kamal accessories updates and optionally apply them
# This script is the main entry point for the GitHub Action
#

set -e

# Check for required dependencies
if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is required but not installed. Please install jq to use this script." >&2
    exit 1
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utilities
source "$SCRIPT_DIR/utils.sh"

# Configuration
CONFIG_DIR="${1:-config}"
MODE="${2:-update-all}"

# Validate inputs
if [ ! -d "$CONFIG_DIR" ]; then
    echo "ERROR: Config directory not found: $CONFIG_DIR" >&2
    exit 1
fi

# Arrays to store update information
declare -a UPDATE_FILES=()
declare -a UPDATE_ACCESSORIES=()
declare -a UPDATE_IMAGES=()
declare -a UPDATE_OLD_VERSIONS=()
declare -a UPDATE_NEW_VERSIONS=()

# Counter for statistics
TOTAL_ACCESSORIES=0
UPDATES_AVAILABLE=0

echo "🔍 Checking for Kamal accessories updates in $CONFIG_DIR..." >&2
echo "" >&2

# Find all deploy*.yml files and process them
while IFS= read -r file; do
    filename=$(basename "$file")

    # Extract accessories section and parse each one
    current_accessory=""
    in_accessories=false

    while IFS= read -r line; do
        # Check if we're entering the accessories section
        if [[ "$line" =~ ^accessories: ]]; then
            in_accessories=true
            continue
        fi

        # Stop processing if we hit another top-level key after accessories
        if $in_accessories && [[ "$line" =~ ^[a-zA-Z] ]]; then
            in_accessories=false
            continue
        fi

        # If we're in the accessories section, look for accessory names and images
        if $in_accessories; then
            # Match accessory names (lines starting with 2 spaces, not 4)
            if [[ "$line" =~ ^[[:space:]]{2}[a-zA-Z_] ]] && ! [[ "$line" =~ ^[[:space:]]{4} ]]; then
                current_accessory=$(echo "$line" | sed 's/^  //; s/:.*$//')
            fi

            # Match image lines
            if [[ "$line" =~ "image:" ]]; then
                # Extract the image part after "image:"
                image_full=$(echo "$line" | sed 's/.*image:[[:space:]]*//')

                # Parse image:version@digest format
                # Remove the @sha256:... part
                image_with_version="${image_full%%@*}"

                # Split image and version
                # Format is: image_name:version
                if [[ "$image_with_version" =~ : ]]; then
                    image="${image_with_version%:*}"
                    version="${image_with_version##*:}"
                else
                    image="$image_with_version"
                    version="latest"
                fi

                TOTAL_ACCESSORIES=$((TOTAL_ACCESSORIES + 1))

                echo "  Checking $current_accessory ($image:$version)..." >&2

                # Get latest version from Docker Hub
                latest_version=$(get_latest_version "$image")

                # Check if update is available
                if [ "$version" != "$latest_version" ] && [ "$latest_version" != "unknown" ]; then
                    # Compare versions to see if latest is actually newer
                    cmp_result=$(compare_versions "$latest_version" "$version")

                    if [ "$cmp_result" = "1" ]; then
                        echo "    ⬆️  Update available: $version → $latest_version" >&2

                        UPDATES_AVAILABLE=$((UPDATES_AVAILABLE + 1))

                        # Store update information
                        UPDATE_FILES+=("$file")
                        UPDATE_ACCESSORIES+=("$current_accessory")
                        UPDATE_IMAGES+=("$image")
                        UPDATE_OLD_VERSIONS+=("$version")
                        UPDATE_NEW_VERSIONS+=("$latest_version")
                    else
                        echo "    ✓ Up to date" >&2
                    fi
                else
                    if [ "$latest_version" = "unknown" ]; then
                        echo "    ⚠️  Could not fetch latest version" >&2
                    else
                        echo "    ✓ Up to date" >&2
                    fi
                fi
            fi
        fi
    done < "$file"
done < <(find "$CONFIG_DIR" -maxdepth 1 -name "deploy*.yml" -type f | sort)

echo "" >&2
echo "📊 Summary: Found $UPDATES_AVAILABLE update(s) available out of $TOTAL_ACCESSORIES accessory(ies)" >&2

# Set GitHub Actions outputs
if [ -n "$GITHUB_OUTPUT" ]; then
    echo "updates-available=$( [ $UPDATES_AVAILABLE -gt 0 ] && echo 'true' || echo 'false' )" >> "$GITHUB_OUTPUT"
    echo "updates-count=$UPDATES_AVAILABLE" >> "$GITHUB_OUTPUT"
fi

# If no updates available, exit early
if [ $UPDATES_AVAILABLE -eq 0 ]; then
    echo "" >&2
    echo "✨ All accessories are up to date!" >&2
    exit 0
fi

# Build JSON output and summary
JSON_OUTPUT="["
UPDATES_SUMMARY=""
FIRST=true

for i in "${!UPDATE_FILES[@]}"; do
    file="${UPDATE_FILES[$i]}"
    accessory="${UPDATE_ACCESSORIES[$i]}"
    image="${UPDATE_IMAGES[$i]}"
    old_version="${UPDATE_OLD_VERSIONS[$i]}"
    new_version="${UPDATE_NEW_VERSIONS[$i]}"

    filename=$(basename "$file")

    # Add to JSON output
    if [ "$FIRST" = false ]; then
        JSON_OUTPUT="$JSON_OUTPUT,"
    fi
    FIRST=false

    JSON_OUTPUT="$JSON_OUTPUT{\"file\":\"$filename\",\"accessory\":\"$accessory\",\"image\":\"$image\",\"old_version\":\"$old_version\",\"new_version\":\"$new_version\"}"

    # Add to summary
    UPDATES_SUMMARY="$UPDATES_SUMMARY- **$accessory** ($filename): \`$old_version\` → \`$new_version\`
"
done

JSON_OUTPUT="$JSON_OUTPUT]"

# Output JSON to GitHub Actions
if [ -n "$GITHUB_OUTPUT" ]; then
    echo "updates-json<<EOF" >> "$GITHUB_OUTPUT"
    echo "$JSON_OUTPUT" >> "$GITHUB_OUTPUT"
    echo "EOF" >> "$GITHUB_OUTPUT"

    echo "updates-summary<<EOF" >> "$GITHUB_OUTPUT"
    echo "$UPDATES_SUMMARY" >> "$GITHUB_OUTPUT"
    echo "EOF" >> "$GITHUB_OUTPUT"
fi

# Apply updates if requested
if [ "$MODE" = "update-all" ] || [ "$MODE" = "update" ]; then
    echo "" >&2
    echo "📝 Applying updates..." >&2
    echo "" >&2

    APPLIED_UPDATES=0
    FAILED_UPDATES=0

    for i in "${!UPDATE_FILES[@]}"; do
        file="${UPDATE_FILES[$i]}"
        accessory="${UPDATE_ACCESSORIES[$i]}"
        image="${UPDATE_IMAGES[$i]}"
        old_version="${UPDATE_OLD_VERSIONS[$i]}"
        new_version="${UPDATE_NEW_VERSIONS[$i]}"

        filename=$(basename "$file")

        # Fetch SHA256 digest for the new version
        echo "  Fetching SHA256 for $image:$new_version..." >&2
        new_sha256=$(get_image_sha256 "$image" "$new_version")

        if [ "$new_sha256" != "unknown" ]; then
            echo "    SHA256: ${new_sha256:0:12}..." >&2
        fi

        # Update the file
        if update_deploy_file "$file" "$accessory" "$old_version" "$new_version" "$new_sha256"; then
            APPLIED_UPDATES=$((APPLIED_UPDATES + 1))
        else
            FAILED_UPDATES=$((FAILED_UPDATES + 1))
        fi
    done

    echo "" >&2
    echo "✅ Applied $APPLIED_UPDATES update(s) successfully" >&2

    if [ $FAILED_UPDATES -gt 0 ]; then
        echo "❌ Failed to apply $FAILED_UPDATES update(s)" >&2
        exit 1
    fi
else
    echo "" >&2
    echo "ℹ️  Mode is set to '$MODE' - updates not applied" >&2
    echo "   Set mode to 'update' or 'update-all' to apply updates" >&2
fi

echo "" >&2
echo "🎉 Done!" >&2
