#!/bin/bash
#
# Utility functions for Kamal Accessories Updater
# Contains shared functions for version comparison and Docker Hub API interactions
#

# Cache configuration
CACHE_DIR="${CACHE_DIR:-/tmp/docker-registry-cache}"
CACHE_TTL="${CACHE_TTL:-3600}"  # 1 hour cache

# Create cache directory
mkdir -p "$CACHE_DIR"

# Function to parse registry from image name
# Returns: "registry|namespace|repo_name"
parse_image_name() {
    local image="$1"
    local registry="docker.io"
    local namespace=""
    local repo_name=""

    # Check if image has registry prefix (e.g., ghcr.io/owner/repo)
    if [[ "$image" == *"/"*"/"* ]]; then
        # Image has format: registry/namespace/repo
        registry="${image%%/*}"
        local remainder="${image#*/}"
        namespace="${remainder%/*}"
        repo_name="${remainder##*/}"
    elif [[ "$image" == *"/"* ]]; then
        # Check if first part is a registry (contains . or :)
        local first_part="${image%%/*}"
        if [[ "$first_part" == *"."* ]] || [[ "$first_part" == *":"* ]]; then
            # Image has format: registry/repo (single level)
            registry="$first_part"
            repo_name="${image#*/}"
            namespace=""
        else
            # Image has format: namespace/repo (Docker Hub)
            registry="docker.io"
            namespace="${image%/*}"
            repo_name="${image##*/}"
        fi
    else
        # Official Docker Hub image (no namespace)
        registry="docker.io"
        namespace="library"
        repo_name="$image"
    fi

    echo "${registry}|${namespace}|${repo_name}"
}

# Function to detect registry type
detect_registry_type() {
    local registry="$1"

    case "$registry" in
        docker.io|registry.hub.docker.com|registry-1.docker.io)
            echo "dockerhub"
            ;;
        ghcr.io)
            echo "ghcr"
            ;;
        gcr.io|*.gcr.io)
            echo "gcr"
            ;;
        quay.io)
            echo "quay"
            ;;
        *)
            # Default to generic OCI registry
            echo "generic"
            ;;
    esac
}

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

# Function to get cache file age in seconds
get_cache_age() {
    local cache_file="$1"

    if [ ! -f "$cache_file" ]; then
        echo 9999999
        return
    fi

    # Try stat with different formats based on OS
    local file_time
    if stat -c%Y "$cache_file" >/dev/null 2>&1; then
        # GNU stat (Linux)
        file_time=$(stat -c%Y "$cache_file")
    elif stat -f%m "$cache_file" >/dev/null 2>&1; then
        # BSD stat (macOS)
        file_time=$(stat -f%m "$cache_file")
    else
        # Fallback: assume cache is old
        echo 9999999
        return
    fi

    local current_time=$(date +%s)
    echo $((current_time - file_time))
}

# ============================================================================
# GHCR (GitHub Container Registry) specific functions
# ============================================================================

# Function to get latest version from GHCR
get_latest_version_ghcr() {
    local namespace="$1"
    local repo_name="$2"
    local cache_key="${3:-ghcr_${namespace}_${repo_name}}"

    local cache_file="$CACHE_DIR/${cache_key}.cache"

    # Check cache
    if [ -f "$cache_file" ]; then
        local file_age=$(get_cache_age "$cache_file")
        if [ $file_age -lt $CACHE_TTL ]; then
            cat "$cache_file"
            return 0
        fi
    fi

    # GHCR uses OCI Distribution API with anonymous token for public repos
    # First, get an anonymous token for public access
    local token=""
    if [ -n "$GHCR_TOKEN" ]; then
        token="$GHCR_TOKEN"
    else
        # Try to get anonymous token
        token=$(curl -s "https://ghcr.io/token?scope=repository:${namespace}/${repo_name}:pull" | jq -r '.token // empty' 2>/dev/null)
    fi

    local api_url="https://ghcr.io/v2/${namespace}/${repo_name}/tags/list"
    local tags_json=""

    if [ -n "$token" ]; then
        tags_json=$(curl -sL -H "Authorization: Bearer $token" "$api_url" 2>/dev/null)
    else
        # Fallback: try without auth (some registries allow it)
        tags_json=$(curl -sL "$api_url" 2>/dev/null)
    fi

    # Validate JSON response
    if ! echo "$tags_json" | jq empty 2>/dev/null; then
        echo "unknown"
        return 1
    fi

    # Extract tag names
    local all_tags=$(echo "$tags_json" | jq -r '.tags[]? // empty' 2>/dev/null)

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

# Function to get SHA256 digest for a specific image tag from GHCR
get_image_sha256_ghcr() {
    local namespace="$1"
    local repo_name="$2"
    local tag="$3"
    local cache_key="${4:-ghcr_${namespace}_${repo_name}_${tag}}"

    local cache_file="$CACHE_DIR/${cache_key}.sha256.cache"

    # Check cache
    if [ -f "$cache_file" ]; then
        local file_age=$(get_cache_age "$cache_file")
        if [ $file_age -lt $CACHE_TTL ]; then
            cat "$cache_file"
            return 0
        fi
    fi

    # Get anonymous token for public access
    local token=""
    if [ -n "$GHCR_TOKEN" ]; then
        token="$GHCR_TOKEN"
    else
        token=$(curl -s "https://ghcr.io/token?scope=repository:${namespace}/${repo_name}:pull" | jq -r '.token // empty' 2>/dev/null)
    fi

    # Get manifest from GHCR
    local manifest_url="https://ghcr.io/v2/${namespace}/${repo_name}/manifests/${tag}"
    local manifest=""

    if [ -n "$token" ]; then
        manifest=$(curl -sL \
            -H "Authorization: Bearer $token" \
            -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
            -H "Accept: application/vnd.oci.image.manifest.v1+json" \
            "$manifest_url" 2>/dev/null)
    else
        manifest=$(curl -sL \
            -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
            -H "Accept: application/vnd.oci.image.manifest.v1+json" \
            "$manifest_url" 2>/dev/null)
    fi

    # Validate JSON response
    if ! echo "$manifest" | jq empty 2>/dev/null; then
        echo "unknown"
        return 1
    fi

    # Extract digest - try config.digest first, then fallback to other fields
    local digest=$(echo "$manifest" | jq -r '.config.digest // .digest // empty' 2>/dev/null)

    if [ -z "$digest" ]; then
        digest="unknown"
    else
        # Strip "sha256:" prefix if present
        digest="${digest#sha256:}"
    fi

    # Cache the result
    echo "$digest" > "$cache_file"
    echo "$digest"
}

# ============================================================================
# Docker Hub specific functions
# ============================================================================

# Function to get latest version from Docker Hub
get_latest_version_dockerhub() {
    local namespace="$1"
    local repo_name="$2"
    local cache_key="${3:-dockerhub_${namespace}_${repo_name}}"

    # Use "library" for official images with no namespace
    if [ -z "$namespace" ]; then
        namespace="library"
    fi

    local cache_file="$CACHE_DIR/${cache_key}.cache"

    # Check cache
    if [ -f "$cache_file" ]; then
        local file_age=$(get_cache_age "$cache_file")
        if [ $file_age -lt $CACHE_TTL ]; then
            cat "$cache_file"
            return 0
        fi
    fi

    # Query Docker Hub API - get multiple tags
    local api_url="https://hub.docker.com/v2/repositories/${namespace}/${repo_name}/tags"
    local tags_json=$(curl -s "$api_url?page_size=100" 2>/dev/null)

    # Validate JSON response
    if ! echo "$tags_json" | jq empty 2>/dev/null; then
        echo "unknown"
        return 1
    fi

    # Extract tag names and filter to only semantic versions
    local all_tags=$(echo "$tags_json" | jq -r '.results[]?.name // empty' 2>/dev/null)

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

# Function to get SHA256 digest for a specific image tag from Docker Hub
get_image_sha256_dockerhub() {
    local namespace="$1"
    local repo_name="$2"
    local tag="$3"
    local cache_key="${4:-dockerhub_${namespace}_${repo_name}_${tag}}"

    # Use "library" for official images with no namespace
    if [ -z "$namespace" ]; then
        namespace="library"
    fi

    local cache_file="$CACHE_DIR/${cache_key}.sha256.cache"

    # Check cache
    if [ -f "$cache_file" ]; then
        local file_age=$(get_cache_age "$cache_file")
        if [ $file_age -lt $CACHE_TTL ]; then
            cat "$cache_file"
            return 0
        fi
    fi

    # Query Docker Hub API for tag info
    local api_url="https://hub.docker.com/v2/repositories/${namespace}/${repo_name}/tags/${tag}"
    local tag_info=$(curl -s "$api_url" 2>/dev/null)

    # Validate JSON response
    if ! echo "$tag_info" | jq empty 2>/dev/null; then
        echo "unknown"
        return 1
    fi

    # Extract digest from tag info - it's in the "images" array
    local digest=$(echo "$tag_info" | jq -r '.images[0].digest // empty' 2>/dev/null)

    if [ -z "$digest" ]; then
        # If Docker Hub API doesn't have it, try to get it from the registry
        digest=$(curl -s -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
            "https://registry-1.docker.io/v2/${namespace}/${repo_name}/manifests/${tag}" 2>/dev/null | \
            jq -r '.config.digest // empty' 2>/dev/null)
    fi

    if [ -z "$digest" ]; then
        digest="unknown"
    else
        # Strip "sha256:" prefix if present
        digest="${digest#sha256:}"
    fi

    # Cache the result
    echo "$digest" > "$cache_file"
    echo "$digest"
}

# ============================================================================
# Main registry dispatcher functions
# ============================================================================

# Function to get SHA256 digest for a specific image tag (dispatcher)
get_image_sha256() {
    local image="$1"
    local tag="$2"

    # Parse image name to extract registry, namespace, and repo
    local parsed=$(parse_image_name "$image")
    local registry=$(echo "$parsed" | cut -d'|' -f1)
    local namespace=$(echo "$parsed" | cut -d'|' -f2)
    local repo_name=$(echo "$parsed" | cut -d'|' -f3)

    # Detect registry type
    local registry_type=$(detect_registry_type "$registry")

    # Create a cache key that includes registry info
    local cache_key="${registry_type}_${namespace}_${repo_name}_${tag}"
    cache_key="${cache_key//\//_}"  # Replace / with _ for filesystem safety

    # Route to appropriate registry handler
    case "$registry_type" in
        dockerhub)
            get_image_sha256_dockerhub "$namespace" "$repo_name" "$tag" "$cache_key"
            ;;
        ghcr)
            get_image_sha256_ghcr "$namespace" "$repo_name" "$tag" "$cache_key"
            ;;
        *)
            # Generic OCI registry support (basic implementation)
            echo "unknown"
            return 1
            ;;
    esac
}

# Function to get latest version (dispatcher)
get_latest_version() {
    local image="$1"

    # Parse image name to extract registry, namespace, and repo
    local parsed=$(parse_image_name "$image")
    local registry=$(echo "$parsed" | cut -d'|' -f1)
    local namespace=$(echo "$parsed" | cut -d'|' -f2)
    local repo_name=$(echo "$parsed" | cut -d'|' -f3)

    # Detect registry type
    local registry_type=$(detect_registry_type "$registry")

    # Create a cache key that includes registry info
    local cache_key="${registry_type}_${namespace}_${repo_name}"
    cache_key="${cache_key//\//_}"  # Replace / with _ for filesystem safety

    # Route to appropriate registry handler
    case "$registry_type" in
        dockerhub)
            get_latest_version_dockerhub "$namespace" "$repo_name" "$cache_key"
            ;;
        ghcr)
            get_latest_version_ghcr "$namespace" "$repo_name" "$cache_key"
            ;;
        *)
            # Generic OCI registry support (basic implementation)
            echo "unknown"
            return 1
            ;;
    esac
}

# Function to update a deploy file with a new version and SHA256
update_deploy_file() {
    local file="$1"
    local accessory="$2"
    local old_version="$3"
    local new_version="$4"
    local new_sha256="$5"  # New SHA256 digest (optional)

    if [ ! -f "$file" ]; then
        echo "ERROR: File not found: $file" >&2
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
        if $in_accessory && [[ "$line" =~ ^[[:space:]]+image:[[:space:]]*(.*) ]]; then
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
        echo "  ✓ Updated $file: $accessory ($old_version → $new_version)" >&2
        return 0
    else
        rm "$temp_file"
        echo "  ✗ Could not update $accessory in $file" >&2
        return 1
    fi
}

# Export functions for use in other scripts
export -f is_semantic_version
export -f normalize_version
export -f compare_versions
export -f get_cache_age
export -f parse_image_name
export -f detect_registry_type
export -f get_latest_version_ghcr
export -f get_image_sha256_ghcr
export -f get_latest_version_dockerhub
export -f get_image_sha256_dockerhub
export -f get_image_sha256
export -f get_latest_version
export -f update_deploy_file
