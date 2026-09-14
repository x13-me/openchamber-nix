#!/bin/sh
# Update versions.nix from upstream openchamber/openchamber releases.
# Usage: update-openchamber.sh [--ci] [--only-check]
#        update-openchamber.sh --fill-system <system>
#   --ci: enable CI mode (run `nix flake update`, append outputs to $GITHUB_OUTPUT).
#   --only-check: dry-run, emit should_update, exit without mutating anything.
#   --fill-system <system>: recompute only that system's nodeModules hash
#     (native FOD build on that system's runner) and rewrite versions.nix
#     in place. No version checks, no flake update, no commit.
# Contract mirrors helium-nix .github/update-helium.sh; upstream-specific
# parts are adapted for openchamber/openchamber (prebuilt web tarball plus
# Linux AppImages per arch plus per-system production node_modules).
# versions.nix stays the sole version source.

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

fill_system=""
prev_arg=""
for arg in "$@"; do
    if [ "$prev_arg" = "--fill-system" ]; then
        fill_system="$arg"
    fi
    prev_arg="$arg"
done

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

update_flake() {
    echo "Updating flake" >&2
    output=$(nix flake update 2>&1)
    status=$?
    echo "$output" | grep '^warning:' >&2 || true
    echo "$output" | grep -v '^warning:' || true
    return $status
}

get_top_field() {
    field="$1"
    grep -oE "^  ${field} = \"[^\"]+\";" versions.nix | sed "s/^  ${field} = \"//;s/\";//"
}

get_system_field() {
    system="$1"
    field="$2"
    awk "/^    ${system} = \\{/,/^    \\};/" versions.nix | grep -oE "${field} = \"[^\"]+\";" | sed "s/${field} = \"//;s/\";//"
}

write_versions_nix() {
    cat > versions.nix << EOF
# Machine-updated by .github/update-openchamber.sh — do not edit by hand.
{
  version = "$1";
  webHash = "$2";
  # Upstream-expected opencode CLI version: the published web tarball's
  # @opencode-ai/sdk pin (tracks the CLI release line; the server has no
  # separate binary-version gate). Maintained by
  # .github/update-openchamber.sh; drives the opencodePackage skew warning.
  opencodeVersion = "$7";
  systems = {
    x86_64-linux = {
      arch = "x86_64";
      appimage = "$3";
      nodeModules = "$5";
    };
    aarch64-linux = {
      arch = "arm64";
      appimage = "$4";
      nodeModules = "$6";
    };
  };
}
EOF
}

# Extract the upstream-expected opencode CLI version from the published web
# tarball: its dependencies pin @opencode-ai/sdk, which tracks the CLI
# release line (no separate binary-version gate exists server-side — the
# wrapper resolves `opencode` off PATH).
extract_opencode_version() {
    version="$1"
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT INT TERM
    if [ -n "$GH_TOKEN" ]; then
        curl -sL -H "Authorization: Bearer ${GH_TOKEN}" "https://github.com/${repo}/releases/download/v${version}/openchamber-web-${version}.tgz" -o "$tmpdir/web.tgz"
    else
        curl -sL "https://github.com/${repo}/releases/download/v${version}/openchamber-web-${version}.tgz" -o "$tmpdir/web.tgz"
    fi
    sdk_version=$(tar -xzf "$tmpdir/web.tgz" -O package/package.json | jq -r '.dependencies["@opencode-ai/sdk"]' | sed 's/^[~^ ]*//')
    rm -rf "$tmpdir"
    trap - EXIT INT TERM
    if ! echo "$sdk_version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'; then
        echo "Error: unexpected @opencode-ai/sdk version: ${sdk_version}" >&2
        exit 1
    fi
    echo "$sdk_version" | tr -d '\000-\037'
}

# Compute a system's production nodeModules FOD hash with a native nix
# build. When versions.nix already pins the right hash the build succeeds
# and the pinned value is reused (idempotent); otherwise the build fails
# with a hash mismatch and the reported hash is extracted. Any other
# failure is fatal and loud.
compute_nodemodules_hash() {
    system="$1"
    set +e
    build_output=$(nix build ".#legacyPackages.${system}.nodeModules" 2>&1)
    status=$?
    set -e
    if [ $status -eq 0 ]; then
        get_system_field "$system" nodeModules
        return 0
    fi
    hash=$(printf '%s\n' "$build_output" | grep -oE 'got:[[:space:]]+sha256-[A-Za-z0-9+/=]+' | head -1 | awk '{print $2}')
    if [ -z "$hash" ]; then
        echo "Error: nodeModules FOD build for ${system} failed without a hash mismatch:" >&2
        printf '%s\n' "$build_output" >&2
        exit 1
    fi
    printf '%s' "$hash" | tr -d '\000-\037'
}

# Recompute one system's nodeModules hash in place (native build on that
# system's runner; refuses to run cross-arch). Used by the aarch64 fill job.
fill_nodemodules() {
    system="$1"
    case "$system" in
        x86_64-linux | aarch64-linux) ;;
        *)
            echo "Error: unknown system '${system}' (expected x86_64-linux or aarch64-linux)" >&2
            exit 1
            ;;
    esac
    host_system=$(nix eval --impure --raw --expr 'builtins.currentSystem' 2> /dev/null || true)
    if [ -n "$host_system" ] && [ "$host_system" != "$system" ]; then
        echo "Error: --fill-system ${system} must run natively on ${system} (this host is ${host_system})" >&2
        exit 1
    fi
    echo "Computing nodeModules hash for ${system} (native build)..."
    new_hash=$(compute_nodemodules_hash "$system")
    if [ "$system" = "x86_64-linux" ]; then
        new_x86_nm="$new_hash"
        new_aarch64_nm=$(get_system_field aarch64-linux nodeModules)
    else
        new_x86_nm=$(get_system_field x86_64-linux nodeModules)
        new_aarch64_nm="$new_hash"
    fi
    write_versions_nix \
        "$(get_top_field version)" \
        "$(get_top_field webHash)" \
        "$(get_system_field x86_64-linux appimage)" \
        "$(get_system_field aarch64-linux appimage)" \
        "$new_x86_nm" \
        "$new_aarch64_nm" \
        "$(get_top_field opencodeVersion)"
    echo "nodeModules hash for ${system}: ${new_hash}"
}

main() {
    set -e

    if [ -n "$fill_system" ]; then
        if $only_check; then
            echo "Error: --fill-system cannot be combined with --only-check" >&2
            exit 1
        fi
        fill_nodemodules "$fill_system"
        exit 0
    fi

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

    echo "Prefetching new hashes..."
    new_web_hash=$(prefetch "https://github.com/${repo}/releases/download/${remote_tag}/openchamber-web-${semantic_version}.tgz")
    new_x86_64_appimage=$(prefetch "https://github.com/${repo}/releases/download/${remote_tag}/OpenChamber-${semantic_version}-linux-x86_64.AppImage")
    new_aarch64_appimage=$(prefetch "https://github.com/${repo}/releases/download/${remote_tag}/OpenChamber-${semantic_version}-linux-arm64.AppImage")

    echo "Extracting expected opencode version..."
    opencode_version=$(extract_opencode_version "$semantic_version")

    # The nodeModules FOD reads versions.nix at eval time, so write the new
    # version first (carrying the old per-system hashes), then compute the
    # native x86_64 hash with a real build and rewrite.
    echo "Updating versions.nix (carrying nodeModules hashes)..."
    old_x86_64_nodemodules=$(get_system_field x86_64-linux nodeModules)
    old_aarch64_nodemodules=$(get_system_field aarch64-linux nodeModules)
    write_versions_nix \
        "$semantic_version" \
        "$new_web_hash" \
        "$new_x86_64_appimage" \
        "$new_aarch64_appimage" \
        "$old_x86_64_nodemodules" \
        "$old_aarch64_nodemodules" \
        "$opencode_version"

    echo "Computing x86_64-linux nodeModules hash (native build)..."
    new_x86_64_nodemodules=$(compute_nodemodules_hash x86_64-linux)

    echo "Updating versions.nix..."
    write_versions_nix \
        "$semantic_version" \
        "$new_web_hash" \
        "$new_x86_64_appimage" \
        "$new_aarch64_appimage" \
        "$new_x86_64_nodemodules" \
        "$old_aarch64_nodemodules" \
        "$opencode_version"

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
