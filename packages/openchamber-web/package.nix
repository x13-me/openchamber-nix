# OpenChamber static web UI assets (`packages/web/dist`), no runtime deps.
{
  lib,
  stdenv,
  builtSource,
}:
stdenv.mkDerivation {
  pname = "openchamber-web";
  inherit (builtSource) version;
  src = builtSource;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/openchamber-web
    cp -a $src/packages/web/dist/. $out/share/openchamber-web/
    runHook postInstall
  '';
  meta = {
    description = "OpenChamber static web UI assets";
    homepage = "https://github.com/openchamber/openchamber";
    license = lib.licenses.mit;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
