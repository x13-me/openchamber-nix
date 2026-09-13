# Internal shared source build: bun install + UI lib build + vite web build.
#
# NOT exposed in `packages` output; `openchamber-server` / `openchamber-web`
# take it as the `builtSource` callPackage argument (wired in
# `packages/default.nix` scope and `nix/overlay.nix` alike).
#
# NOTE: the build phase needs network (bun registry). Build with
# `--option sandbox false` if your builder denies network access.
# Sandboxing is deliberately NOT disabled here in code — see README
# "Why builds need network".
{
  lib,
  stdenv,
  fetchFromGitHub,
  bun,
  nodejs_22,
}:
let
  versions = import ../../versions.nix;
in
stdenv.mkDerivation {
  pname = "openchamber-built-source";
  inherit (versions) version;
  src = fetchFromGitHub {
    owner = "openchamber";
    repo = "openchamber";
    inherit (versions) rev;
    hash = versions.srcHash;
  };
  nativeBuildInputs = [
    bun
    nodejs_22
  ];
  buildPhase = ''
    runHook preBuild
    export HOME="$TMPDIR" BUN_INSTALL_CACHE_DIR="$TMPDIR/bun-cache"
    bun install --frozen-lockfile
    bun run --cwd packages/ui build
    bun run --cwd packages/web build
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    # Keep workspace layout intact: root node_modules holds RELATIVE
    # symlinks into packages/*, so both must be copied together.
    cp -a package.json node_modules packages $out/
    # Tolerate either text (bun.lock) or binary (bun.lockb) lockfile.
    for lockfile in bun.lock bun.lockb; do
      [ -e "$lockfile" ] && cp -a "$lockfile" $out/
    done
    runHook postInstall
  '';
  meta = {
    description = "OpenChamber built workspace source (internal)";
    homepage = "https://github.com/openchamber/openchamber";
    license = lib.licenses.mit;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
