# OpenChamber server + CLI (`openchamber serve`), wrapping the built
# `@openchamber/web` workspace with nodejs_22.
{
  lib,
  stdenv,
  makeWrapper,
  nodejs_22,
  cacert,
  opencode,
  git,
  openssh,
  bash,
  builtSource,
}:
stdenv.mkDerivation {
  pname = "openchamber-server";
  inherit (builtSource) version;
  src = builtSource;
  dontBuild = true;
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/openchamber $out/bin
    cp -a $src/package.json $src/node_modules $src/packages $out/lib/openchamber/
    # Tolerate either text (bun.lock) or binary (bun.lockb) lockfile.
    for lockfile in "$src"/bun.lock "$src"/bun.lockb; do
      [ -e "$lockfile" ] && cp -a "$lockfile" $out/lib/openchamber/
    done
    makeWrapper ${nodejs_22}/bin/node $out/bin/openchamber \
      --add-flags "$out/lib/openchamber/packages/web/bin/cli.js" \
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
