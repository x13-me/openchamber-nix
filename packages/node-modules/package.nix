# Internal production `node_modules` for the prebuilt `@openchamber/web` tarball.
#
# Fixed-output derivation: network IS allowed inside the sandbox here (the
# sanctioned FOD mechanism), so — unlike the old built-source path — this
# builds on locked-down machines with no `--option sandbox false`.
#
# NOT exposed in `packages` output; `openchamber-server` takes it as the
# `nodeModules` callPackage argument (wired in `packages/default.nix` scope
# and `nix/overlay.nix` alike).
#
# Per-system `nodeModules` output hashes live in `versions.nix` (same pattern
# as the GUI AppImage hashes): npm installs platform-specific optional deps
# (`sherpa-onnx-linux-x64` vs `-linux-arm64`, ...), so x86_64 and aarch64
# trees differ and cannot share one hash.
{
  lib,
  stdenv,
  fetchurl,
  nodejs_22,
  cacert,
}:
let
  versions = import ../../versions.nix;
  system = stdenv.hostPlatform.system;
  nodeModulesHash =
    versions.systems.${system}.nodeModules
      or (throw "openchamber-nix: no nodeModules hash for system ${system} (see versions.nix)");
in
stdenv.mkDerivation {
  pname = "openchamber-node-modules";
  inherit (versions) version;
  src = fetchurl {
    url = "https://github.com/openchamber/openchamber/releases/download/v${versions.version}/openchamber-web-${versions.version}.tgz";
    hash = versions.webHash;
  };
  # Fail fast when upstream rearranges the tarball layout.
  sourceRoot = "package";
  outputHash = nodeModulesHash;
  outputHashMode = "recursive";
  nativeBuildInputs = [
    nodejs_22
    cacert
  ];
  buildPhase = ''
    runHook preBuild
    export HOME="$TMPDIR"
    export npm_config_cache="$TMPDIR/npm-cache"
    export SSL_CERT_FILE="${cacert}/etc/ssl/certs/ca-bundle.crt"
    export NODE_EXTRA_CA_CERTS="$SSL_CERT_FILE"
    export NPM_CONFIG_CAFILE="$SSL_CERT_FILE"
    # The published tarball lists 52 devDependencies (vite/vitest/...) that
    # `--omit=dev` would prune anyway; strip them first so npm's resolver
    # never walks their peer graph (npm 10 cannot resolve it:
    # `edgesOut of null`). The installed production tree is identical
    # with or without them.
    node -e 'const fs=require("fs");const p=JSON.parse(fs.readFileSync("package.json","utf8"));delete p.devDependencies;fs.writeFileSync("package.json",JSON.stringify(p,null,2));'
    npm install --omit=dev --no-audit --no-fund --no-update-notifier --no-progress
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -a node_modules/. $out/
    runHook postInstall
  '';
  meta = {
    description = "OpenChamber web production node_modules (internal)";
    homepage = "https://github.com/openchamber/openchamber";
    license = lib.licenses.mit;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
