#!/bin/sh
# Update versions.nix from upstream openchamber/openchamber releases.
# Usage: update-openchamber.sh [--ci] [--only-check]
#   --ci: enable CI mode (run `nix flake update`, append outputs to $GITHUB_OUTPUT).
#   --only-check: dry-run, emit should_update, exit without mutating anything.
# Contract mirrors helium-nix .github/update-helium.sh; upstream-specific
# parts are adapted for openchamber/openchamber (Linux AppImages per arch
# plus git source rev/srcHash). versions.nix stays the sole version source.

repo="openchamber/openchamber"
api_base="https://api.github.com/repos/${repo}"

ci=false
if echo "$@" | grep -qoE '(--ci)'; then
    ci=true
fi

only_check=false
if echo "$@" | grep -qoE '(--only-check)'; then
    only_check=true
fi

with_retry() {
    retries=5
    count=0
    output=""
    status=0

    while [ $count -lt $retries ]; do
        output=$("$@" 2>&1)
        status=$?

        if echo "$output" | grep -q 'Not Found'; then
            count=$((count + 1))
            echo "attempt $count/$retries: 404 Not Found encountered, retrying..." >&2
            sleep 1
        else
            echo "[TRACE] [cmd=$*] output: $output" 1>&2
            echo "$output" | tr -d '\000-\037'
            return $status
        fi
    done

    echo "max retries reached. last output: $output (cmd=$*)" >&2
    exit 1
}

api_get() {
    if [ -n "$GH_TOKEN" ]; then
        echo "ATTEMPTING WITH TOKEN" 1>&2
        with_retry curl -s -H "Authorization: Bearer ${GH_TOKEN}" "$1"
    else
        echo "GH_TOKEN NOT SET!!!!!!!" 1>&2
        with_retry curl -s "$1"
    fi
}

get_latest_release() {
    echo "GETTING LATEST RELEASE" 1>&2
    api_get "${api_base}/releases/latest"
}

parse_field() {
    field="$1"
    grep -o "\"${field}\": *\"[^\"]*\"" | head -1 | sed "s/\"${field}\": *\"//;s/\"$//"
}

check_api_response() {
    response="$1"
    message=$(echo "$response" | parse_field message)
    if [ -n "$message" ]; then
        echo "GitHub API error: $message" >&2
        exit 1
    fi
}

get_current_version() {
    grep -oE 'version = "[^"]+";' versions.nix | sed 's/version = "//;s/";//'
}

prefetch() {
    nix store prefetch-file --hash-type sha256 --json "$1" | jq -r '.hash'
}

prefetch_source() {
    nix store prefetch-file --unpack --hash-type sha256 --json "$1" | jq -r '.hash'
}

update_flake() {
    echo "Updating flake" >&2
    output=$(nix flake update 2>&1)
    status=$?
    echo "$output" | grep '^warning:' >&2 || true
    echo "$output" | grep -v '^warning:' || true
    return $status
}

write_versions_nix() {
    cat > versions.nix << EOF
# Machine-updated by .github/update-openchamber.sh — do not edit by hand.
{
  version = "$1";
  rev = "$2";
  srcHash = "$3";
  systems = {
    x86_64-linux = {
      arch = "x86_64";
      appimage = "$4";
    };
    aarch64-linux = {
      arch = "arm64";
      appimage = "$5";
    };
  };
}
EOF
}

# Resolve a release tag to its commit SHA. Annotated tags point at a tag
# object rather than a commit, so dereference to the commit SHA before pinning.
resolve_rev() {
    tag="$1"
    ref_json=$(api_get "${api_base}/git/ref/tags/${tag}")
    check_api_response "$ref_json"
    rev=$(echo "$ref_json" | parse_field sha | head -1)
    obj_type=$(echo "$ref_json" | grep -o '"type": *"[^"]*"' | head -1 | sed 's/"type": *"//;s/"//')
    if [ "$obj_type" = "tag" ]; then
        tag_json=$(api_get "${api_base}/git/tags/${rev}")
        check_api_response "$tag_json"
        rev=$(echo "$tag_json" | grep -o '"sha": *"[^"]*"' | tail -1 | sed 's/"sha": *"//;s/"//')
    fi
    if [ -z "$rev" ] || [ "$rev" = "null" ]; then
        echo "Error: failed to resolve tag ${tag} to a commit SHA" >&2
        exit 1
    fi
    echo "$rev"
}

main() {
    set -e

    echo "Fetching latest OpenChamber release..."
    latest_release=$(get_latest_release)
    check_api_response "$latest_release"

    remote_tag=$(echo "$latest_release" | parse_field tag_name)

    if [ -z "$remote_tag" ] || [ "$remote_tag" = "null" ]; then
        echo "Error: could not parse tag_name from GitHub API response:" >&2
        echo "$latest_release" >&2
        exit 1
    fi

    # Upstream tags carry a leading `v` (e.g. v1.23.0); versions.nix stores
    # the bare semantic version, and the workflow tag step re-adds the `v`.
    semantic_version=$(echo "$remote_tag" | sed 's/^v//')

    if ! echo "$semantic_version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'; then
        echo "Error: unexpected version format: ${semantic_version} (from tag ${remote_tag})" >&2
        exit 1
    fi

    local_version=$(get_current_version)

    echo "Checking version... local=$local_version remote=$semantic_version (tag=$remote_tag)"

    if [ "$local_version" = "$semantic_version" ]; then
        echo "Local OpenChamber version is up to date"
        if $only_check && $ci; then
            echo "should_update=false" >> "$GITHUB_OUTPUT"
        fi
        exit 0
    fi

    echo "Local OpenChamber version is outdated, updating from $local_version to $semantic_version"

    if $only_check; then
        if $ci; then
            echo "should_update=true" >> "$GITHUB_OUTPUT"
        else
            echo "should_update=true"
        fi
        exit 0
    fi

    echo "Resolving tag ${remote_tag} to commit SHA..."
    rev=$(resolve_rev "$remote_tag")

    echo "Prefetching new hashes..."
    src_hash=$(prefetch_source "https://github.com/${repo}/archive/${rev}.tar.gz")
    new_x86_64_appimage=$(prefetch "https://github.com/${repo}/releases/download/${remote_tag}/OpenChamber-${semantic_version}-linux-x86_64.AppImage")
    new_aarch64_appimage=$(prefetch "https://github.com/${repo}/releases/download/${remote_tag}/OpenChamber-${semantic_version}-linux-arm64.AppImage")

    echo "Updating versions.nix..."
    write_versions_nix \
    "$semantic_version" \
    "$rev" \
    "$src_hash" \
    "$new_x86_64_appimage" \
    "$new_aarch64_appimage"

    echo "Updated OpenChamber from $local_version to $semantic_version"

    if $ci; then
        update_output=$(update_flake)
    else
        update_flake
    fi

    if $ci; then
        delimiter="EOF_$(date +%s)_$$"

        {
            echo "commit_message<<${delimiter}"
            echo "chore(update): openchamber to ${semantic_version}"
            if [ -n "$update_output" ]; then
                echo ""
                echo "$update_output"
            fi
            echo "${delimiter}"
            echo "should_update=true"
            echo "version=${semantic_version}"
        } >> "$GITHUB_OUTPUT"
    fi
}

main
