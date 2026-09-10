#!/usr/bin/env bash
# Update versions.nix from upstream openchamber/openchamber releases.
# Usage: update-openchamber.sh [--only-check]
#   --only-check: exit 0 with GITHUB_OUTPUT should_update=true/false, no changes.
set -euo pipefail

REPO="openchamber/openchamber"
VERSIONS_FILE="$(dirname "$0")/../versions.nix"
ONLY_CHECK=false
[[ "${1:-}" == "--only-check" ]] && ONLY_CHECK=true

# Latest stable release (excludes prereleases/drafts), matching releases/latest.
latest_tag="$(gh release view -R "$REPO" --json tagName --jq .tagName)"
current_version="$(nix eval --impure --expr "(import ./${VERSIONS_FILE}).version" --raw)"

commit_message="chore: update openchamber to ${latest_tag}"
echo "Latest upstream: ${latest_tag}, current: ${current_version}"

if [[ "$latest_tag" == "$current_version" || "v${current_version}" == "$latest_tag" ]]; then
  echo "Already up to date."
  [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "should_update=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

if $ONLY_CHECK; then
  [[ -n "${GITHUB_OUTPUT:-}" ]] && {
    echo "should_update=true" >> "$GITHUB_OUTPUT"
    echo "version=${latest_tag}" >> "$GITHUB_OUTPUT"
    echo "commit_message=${commit_message}" >> "$GITHUB_OUTPUT"
  }
  exit 0
fi

version="${latest_tag#v}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || {
  echo "Unexpected version format: ${version} (from tag ${latest_tag})" >&2
  exit 1
}

# Resolve the tag ref. Annotated tags point at a tag object rather than a
# commit, so dereference to the commit SHA before pinning rev.
ref_json="$(gh api "repos/${REPO}/git/ref/tags/${latest_tag}")"
rev="$(jq -r .object.sha <<<"$ref_json")"
if [[ "$(jq -r .object.type <<<"$ref_json")" == "tag" ]]; then
  rev="$(gh api "repos/${REPO}/git/tags/${rev}" --jq .object.sha)"
fi
[[ -n "${rev:-}" ]] || {
  echo "Failed to resolve tag ${latest_tag} to a commit SHA" >&2
  exit 1
}
src_hash="$(nix store prefetch-file --unpack --json "https://github.com/${REPO}/archive/${rev}.tar.gz" | jq -r .hash)"

declare -A arch_map=( [x86_64-linux]="x86_64" [aarch64-linux]="arm64" )
declare -A hashes
for system in x86_64-linux aarch64-linux; do
  arch="${arch_map[$system]}"
  url="https://github.com/${REPO}/releases/download/${latest_tag}/OpenChamber-${version}-linux-${arch}.AppImage"
  hashes[$system]="$(nix store prefetch-file --json "$url" | jq -r .hash)"
done

cat > "$VERSIONS_FILE" <<EOF
# Machine-updated by .github/update-openchamber.sh — do not edit by hand.
{
  version = "${version}";
  rev = "${rev}";
  srcHash = "${src_hash}";
  systems = {
    x86_64-linux = {
      arch = "x86_64";
      appimage = "${hashes[x86_64-linux]}";
    };
    aarch64-linux = {
      arch = "arm64";
      appimage = "${hashes[aarch64-linux]}";
    };
  };
}
EOF

nix flake update

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "should_update=true" >> "$GITHUB_OUTPUT"
  echo "version=${latest_tag}" >> "$GITHUB_OUTPUT"
  echo "commit_message=${commit_message}" >> "$GITHUB_OUTPUT"
fi
