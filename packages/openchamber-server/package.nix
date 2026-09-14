# OpenChamber server + CLI (`openchamber serve`): prebuilt `@openchamber/web`
# release tarball repackaged with production `node_modules`, wrapped with
# nodejs_22.
{
  lib,
  stdenv,
  fetchurl,
  makeWrapper,
  nodejs_22,
  cacert,
  opencode,
  git,
  openssh,
  bash,
  nodeModules,
}:
let
  versions = import ../../versions.nix;
  webSrc = fetchurl {
    url = "https://github.com/openchamber/openchamber/releases/download/v${versions.version}/openchamber-web-${versions.version}.tgz";
    hash = versions.webHash;
  };
in
stdenv.mkDerivation {
  pname = "openchamber-server";
  inherit (versions) version;
  src = webSrc;
  # Fail fast when upstream rearranges the tarball layout.
  sourceRoot = "package";
  dontBuild = true;
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/openchamber $out/bin
    # Upstream's published layout: ready-built `dist/` + `server/` +
    # `bin/cli.js`. Halt with a clear error when that contract breaks.
    for required in package.json bin/cli.js server/index.js dist/index.html; do
      [ -e "$required" ] || { echo "openchamber-server: missing $required in openchamber-web tarball" >&2; exit 1; }
    done
    cp -a package.json bin server dist $out/lib/openchamber/
    [ -e public ] && cp -a public $out/lib/openchamber/
    cp -a ${nodeModules} $out/lib/openchamber/node_modules
    makeWrapper ${nodejs_22}/bin/node $out/bin/openchamber \
      --add-flags "$out/lib/openchamber/bin/cli.js" \
      --prefix PATH : "${
        lib.makeBinPath [
          opencode
          git
          openssh
          bash
        ]
      }" \
      --set NODE_PATH "$out/lib/openchamber/node_modules" \
      --set SSL_CERT_FILE "${cacert}/etc/ssl/certs/ca-bundle.crt"
    runHook postInstall
  '';
  meta = {
    description = "OpenChamber server + CLI (openchamber serve)";
    homepage = "https://github.com/openchamber/openchamber";
    license = lib.licenses.mit;
    mainProgram = "openchamber";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
