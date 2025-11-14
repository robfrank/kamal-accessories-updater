#!/bin/bash

# Extract image names and versions for accessories from deploy*.yml files
# Also checks for newer versions available on Docker Hub
# Usage: ./extract-accessories.sh [output_format|update]
# output_format: "table" (default), "json", or "csv"
# update: Update deploy files with new versions

OUTPUT_FORMAT="${1:-table}"
CONFIG_DIR="config"
CACHE_DIR="/tmp/docker-registry-cache"
CACHE_TTL=3600  # 1 hour cache
UPDATE_MODE=false
UPDATE_ALL=false
JSON_ITEMS=()  # Array to collect JSON items for update processing

# Check if update mode is requested
if [ "$OUTPUT_FORMAT" = "update" ]; then
    UPDATE_MODE=true
    OUTPUT_FORMAT="json"
elif [ "$OUTPUT_FORMAT" = "update-all" ]; then
    UPDATE_MODE=true
    UPDATE_ALL=true
    OUTPUT_FORMAT="json"
fi

# Create cache directory
mkdir -p "$CACHE_DIR"

# Colors for table output
if [ "$OUTPUT_FORMAT" = "table" ]; then
    BOLD='\033[1m'
    NC='\033[0m' # No Color
fi

# Function to check if a string looks like a semantic version
is_semantic_version() {
    local tag="$1"
    # Match patterns like: 1.0.0, v1.0.0, 1.0, v1.0, 2025.10.0, etc.
    if [[ "$tag" =~ ^v?[0-9]+(\.[0-9]+)*$ ]]; then
        return 0
    fi
    return 1
}

# Function to normalize version for comparison (remove 'v' prefix)
normalize_version() {
    local version="$1"
    echo "$version" | sed 's/^v//'
}

# Function to compare two semantic versions
# Returns 1 if version1 > version2, 0 if equal, -1 if version1 < version2
compare_versions() {
    local v1=$(normalize_version "$1")
    local v2=$(normalize_version "$2")

    # Handle simple case where versions are equal
    if [ "$v1" = "$v2" ]; then
        echo 0
        return
    fi

    # Use printf and basic string comparison with padding
    # Split by dots and compare each part numerically
    local IFS='.'
    local -a parts1=($v1)
    local -a parts2=($v2)

    local len=${#parts1[@]}
    if [ ${#parts2[@]} -gt $len ]; then
        len=${#parts2[@]}
    fi

    for ((i=0; i<len; i++)); do
        local p1=${parts1[$i]:-0}
        local p2=${parts2[$i]:-0}

        # Remove non-numeric suffixes for comparison
        p1=${p1%%[^0-9]*}
        p2=${p2%%[^0-9]*}

        p1=${p1:-0}
        p2=${p2:-0}

        if [ $p1 -gt $p2 ]; then
            echo 1
            return
        elif [ $p1 -lt $p2 ]; then
            echo -1
            return
        fi
    done

    echo 0
}

# Function to update a deploy file with a new version and SHA256
update_deploy_file() {
    local file="$1"
    local accessory="$2"
    local old_version="$3"
    local new_version="$4"
    local new_sha256="$5"  # New SHA256 digest (optional)

    if [ ! -f "$file" ]; then
        echo "ERROR: File not found: $file"
        return 1
    fi

    # Prepare the new image line
    local new_image_line=""
    if [ -n "$new_sha256" ] && [ "$new_sha256" != "unknown" ]; then
        new_image_line="${new_version}@sha256:${new_sha256}"
    else
        new_image_line="${new_version}"
    fi

    # Read the file and find the accessory section, then update the version
    local found=false
    local in_accessory=false
    local updated=false
    local temp_file=$(mktemp)

    while IFS= read -r line; do
        # Check if we're entering this accessory section
        if [[ "$line" =~ ^[[:space:]]{2}${accessory}:[[:space:]]*$ ]]; then
            in_accessory=true
            echo "$line" >> "$temp_file"
            continue
        fi

        # If we were in the accessory section and hit another key at same level, we're done
        if $in_accessory && [[ "$line" =~ ^[[:space:]]{2}[a-zA-Z_] ]] && ! [[ "$line" =~ ^[[:space:]]{2}${accessory} ]]; then
            in_accessory=false
        fi

        # If we're in the right accessory section, look for the image line
        if $in_accessory && [[ "$line" =~ image:[[:space:]]*(.*) ]]; then
            local image_line="${BASH_REMATCH[1]}"

            # Extract image name (everything before :version@sha256...)
            local image_name=$(echo "$image_line" | sed 's/:.*$//')

            # Replace entire image line with new image:version@sha256
            local updated_line="${image_name}:${new_image_line}"

            if [ "$image_line" != "$updated_line" ]; then
                # Get indentation from original line
                local indent=$(echo "$line" | sed 's/[^ \t].*$//')
                echo "${indent}image: $updated_line" >> "$temp_file"
                updated=true
                found=true
                in_accessory=false
                continue
            fi
        fi

        echo "$line" >> "$temp_file"
    done < "$file"

    if [ "$updated" = true ]; then
        mv "$temp_file" "$file"
        echo "Updated $file: $accessory ($old_version → $new_version)"
        return 0
    else
        rm "$temp_file"
        echo "WARNING: Could not find version $old_version for $accessory in $file"
        return 1
    fi
}

# Function to get SHA256 digest for a specific image tag from Docker Hub
get_image_sha256() {
    local image="$1"
    local tag="$2"
    local namespace=""
    local repo_name=""

    # Parse image name
    if [[ "$image" == *"/"* ]]; then
        namespace="${image%/*}"
        repo_name="${image##*/}"
    else
        namespace="library"
        repo_name="$image"
    fi

    local cache_file="$CACHE_DIR/${namespace}_${repo_name}_${tag}.sha256.cache"

    # Check cache
    if [ -f "$cache_file" ]; then
        local file_age=$(($(date +%s) - $(stat -f%m "$cache_file" 2>/dev/null || echo 0)))
        if [ $file_age -lt $CACHE_TTL ]; then
            cat "$cache_file"
            return 0
        fi
    fi

    # Query Docker Hub API for tag info
    local api_url="https://hub.docker.com/v2/repositories/${namespace}/${repo_name}/tags/${tag}"
    local tag_info=$(curl -s "$api_url" 2>/dev/null)

    # Extract digest from tag info - it's in the "images" array
    local digest=$(echo "$tag_info" | grep -o '"digest":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -z "$digest" ]; then
        # If Docker Hub API doesn't have it, try to get it from the registry
        # This requires a different approach - use curl with manifest request
        digest=$(curl -s -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
            "https://registry-1.docker.io/v2/${namespace}/${repo_name}/manifests/${tag}" 2>/dev/null | \
            grep -o '"config":\s*{[^}]*"digest":"[^"]*"' | cut -d'"' -f6)
    fi

    if [ -z "$digest" ]; then
        digest="unknown"
    else
        # Strip "sha256:" prefix if present (API returns it with prefix)
        digest="${digest#sha256:}"
    fi

    # Cache the result
    echo "$digest" > "$cache_file"
    echo "$digest"
}

# Function to get latest version from Docker Hub
get_latest_version() {
    local image="$1"
    local namespace=""
    local repo_name=""

    # Parse image name
    if [[ "$image" == *"/"* ]]; then
        namespace="${image%/*}"
        repo_name="${image##*/}"
    else
        # Official Docker Hub image (no namespace)
        namespace="library"
        repo_name="$image"
    fi

    local cache_file="$CACHE_DIR/${namespace}_${repo_name}.cache"

    # Check cache
    if [ -f "$cache_file" ]; then
        local file_age=$(($(date +%s) - $(stat -f%m "$cache_file" 2>/dev/null || echo 0)))
        if [ $file_age -lt $CACHE_TTL ]; then
            cat "$cache_file"
            return 0
        fi
    fi

    # Query Docker Hub API - get multiple tags
    local api_url="https://hub.docker.com/v2/repositories/${namespace}/${repo_name}/tags"
    local tags_json=$(curl -s "$api_url?page_size=100" 2>/dev/null)

    # Extract tag names and filter to only semantic versions
    local all_tags=$(echo "$tags_json" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)

    local latest_tag=""
    local latest_version=""

    while IFS= read -r tag; do
        # Skip empty lines
        [ -z "$tag" ] && continue

        # Filter out known non-version tags
        if echo "$tag" | grep -qi 'latest\|main\|master\|dev\|develop\|nightly\|alpha\|beta\|sha256\|digest'; then
            continue
        fi

        # Only consider semantic versions
        if is_semantic_version "$tag"; then
            if [ -z "$latest_version" ]; then
                latest_tag="$tag"
                latest_version="$tag"
            else
                # Compare versions
                local cmp_result=$(compare_versions "$tag" "$latest_version")
                if [ "$cmp_result" = "1" ]; then
                    latest_tag="$tag"
                    latest_version="$tag"
                fi
            fi
        fi
    done <<< "$all_tags"

    if [ -z "$latest_tag" ]; then
        latest_tag="unknown"
    fi

    # Cache the result
    echo "$latest_tag" > "$cache_file"
    echo "$latest_tag"
}

case "$OUTPUT_FORMAT" in
    json)
        echo "["
        first=true
        ;;
    csv)
        echo "File,Accessory,Image,Version,LatestVersion,UpdateAvailable"
        ;;
    table)
        printf "${BOLD}%-35s %-25s %-50s %-20s %-20s${NC}\n" "File" "Accessory" "Image" "Version" "Latest"
        printf "%.0s-" {1..150}
        echo
        ;;
esac

# Temporary file for storing JSON items when in update mode
JSON_TEMP_FILE=""
if [ "$UPDATE_MODE" = true ]; then
    JSON_TEMP_FILE=$(mktemp)
fi

# Find all deploy*.yml files and process them
find "$CONFIG_DIR" -maxdepth 1 -name "deploy*.yml" -type f | sort | while read file; do
    filename=$(basename "$file")

    # Extract accessories section and parse each one
    # Match lines like: "  accessory_name:" or "    image: ..."
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

                # Get latest version from Docker Hub
                latest_version=$(get_latest_version "$image")

                # Determine if update is available (simple string comparison)
                update_available=""
                if [ "$version" != "$latest_version" ] && [ "$latest_version" != "unknown" ]; then
                    update_available="*"
                fi

                # Prepare JSON object
                json_obj="{\"file\": \"$filename\", \"accessory\": \"$current_accessory\", \"image\": \"$image\", \"version\": \"$version\", \"latest_version\": \"$latest_version\", \"update_available\": $([ -n "$update_available" ] && echo 'true' || echo 'false')}"

                # If in update mode, write to temp file
                if [ "$UPDATE_MODE" = true ] && [ -n "$JSON_TEMP_FILE" ]; then
                    echo "$json_obj" >> "$JSON_TEMP_FILE"
                fi

                # Output in requested format
                case "$OUTPUT_FORMAT" in
                    json)
                        if [ "$first" = false ]; then
                            echo ","
                        fi
                        echo -n "  $json_obj"
                        first=false
                        ;;
                    csv)
                        echo "$filename,$current_accessory,$image,$version,$latest_version,$update_available"
                        ;;
                    table)
                        if [ -n "$update_available" ]; then
                            # Highlight outdated versions
                            printf "%-35s %-25s %-50s %-20s %-20s %s\n" "$filename" "$current_accessory" "$image" "$version" "$latest_version" "UPDATE"
                        else
                            printf "%-35s %-25s %-50s %-20s %-20s\n" "$filename" "$current_accessory" "$image" "$version" "$latest_version"
                        fi
                        ;;
                esac
            fi
        fi
    done < "$file"
done

if [ "$UPDATE_MODE" = true ]; then
    # In update mode, suppress normal output
    :
else
    # Normal output mode
    case "$OUTPUT_FORMAT" in
        json)
            echo ""
            echo "]"
            ;;
    esac
fi

# If update mode is enabled, process the updates from temp file
if [ "$UPDATE_MODE" = true ] && [ -n "$JSON_TEMP_FILE" ] && [ -f "$JSON_TEMP_FILE" ]; then
    echo "" >&2
    echo "=== Updating deploy files with new versions ===" >&2

    # Count total updates available
    total_updates=$(grep -c '"update_available": true' "$JSON_TEMP_FILE" 2>/dev/null || echo 0)

    if [ "$total_updates" -eq 0 ]; then
        echo "No updates available!" >&2
        rm -f "$JSON_TEMP_FILE"
        exit 0
    fi

    echo "Found $total_updates updates available:" >&2

    # Process each item from temp file
    while IFS= read -r json_obj; do
        # Extract fields using grep
        file=$(echo "$json_obj" | grep -o '"file": "[^"]*"' | cut -d'"' -f4)
        accessory=$(echo "$json_obj" | grep -o '"accessory": "[^"]*"' | cut -d'"' -f4)
        image=$(echo "$json_obj" | grep -o '"image": "[^"]*"' | cut -d'"' -f4)
        version=$(echo "$json_obj" | grep -o '"version": "[^"]*"' | cut -d'"' -f4)
        latest_version=$(echo "$json_obj" | grep -o '"latest_version": "[^"]*"' | cut -d'"' -f4)
        update_available=$(echo "$json_obj" | grep -o '"update_available": [^}]*' | cut -d' ' -f2)

        if [ "$update_available" = "true" ]; then
            # Construct full file path
            full_path="$CONFIG_DIR/$file"

            # Fetch SHA256 digest for the new version
            echo "  Fetching SHA256 digest for $image:$latest_version..." >&2
            new_sha256=$(get_image_sha256 "$image" "$latest_version")

            if [ "$new_sha256" = "unknown" ]; then
                echo "  WARNING: Could not fetch SHA256 digest for $image:$latest_version" >&2
            fi

            # Check if in automatic mode
            if [ "$UPDATE_ALL" = true ]; then
                # Auto-update without prompting
                echo "" >&2
                echo "Updating $accessory in $file" >&2
                echo "  $version → $latest_version" >&2
                if [ "$new_sha256" != "unknown" ]; then
                    echo "  SHA256: ${new_sha256:0:12}..." >&2
                fi
                update_deploy_file "$full_path" "$accessory" "$version" "$latest_version" "$new_sha256" 2>&1 | sed 's/^/  /' >&2
            else
                # Prompt user for confirmation
                echo "" >&2
                echo "Update available: $accessory in $file" >&2
                echo "  Current:  $version" >&2
                echo "  Latest:   $latest_version" >&2
                if [ "$new_sha256" != "unknown" ]; then
                    echo "  SHA256:   ${new_sha256:0:12}..." >&2
                fi
                read -p "  Update? (y/n): " -n 1 -r confirm >&2
                echo "" >&2

                if [[ $confirm =~ ^[Yy]$ ]]; then
                    update_deploy_file "$full_path" "$accessory" "$version" "$latest_version" "$new_sha256" 2>&1 | sed 's/^/  /' >&2
                fi
            fi
        fi
    done < "$JSON_TEMP_FILE"

    rm -f "$JSON_TEMP_FILE"
    echo "" >&2
    echo "=== Update Complete ===" >&2
fi
