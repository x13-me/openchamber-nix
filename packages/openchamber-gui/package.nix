# OpenChamber desktop GUI: upstream Linux AppImage repackaged with
# `appimageTools.wrapType2`, desktop entry `Exec` fixed, icons installed.
#
# NOTE: electron-updater self-update is disabled by design here —
# the AppImage lives in the immutable Nix store.
{
  lib,
  stdenv,
  fetchurl,
  appimageTools,
}:
let
  versions = import ../../versions.nix;
  system = stdenv.hostPlatform.system;
  arch = (import ../../lib { inherit lib; }).archOf versions system;
  # Fetch once; shared by wrapType2 and the icon/desktop extraction.
  appSrc = fetchurl {
    url = "https://github.com/openchamber/openchamber/releases/download/v${versions.version}/OpenChamber-${versions.version}-linux-${arch}.AppImage";
    hash = versions.systems.${system}.appimage;
  };
in
appimageTools.wrapType2 {
  pname = "openchamber-gui";
  inherit (versions) version;
  src = appSrc;
  extraInstallCommands =
    let
      extracted = appimageTools.extract {
        pname = "openchamber-gui";
        inherit (versions) version;
        src = appSrc;
      };
    in
    ''
      for desktop in ${extracted}/*.desktop; do
        install -Dm444 "$desktop" -t $out/share/applications
      done
      sed -i 's|^Exec=AppRun.*|Exec=openchamber-gui|' $out/share/applications/*.desktop
      if [ -d ${extracted}/usr/share/icons ]; then
        cp -r ${extracted}/usr/share/icons $out/share/
        # The extracted store tree is read-only; `cp -r` preserves those
        # modes, so re-grant owner write or the icon install below fails
        # with "Permission denied" on the copied directory.
        chmod -R u+w $out/share/icons
      fi
      for icon in ${extracted}/*.png ${extracted}/*.svg; do
        [ -f "$icon" ] || continue
        ext="''${icon##*.}"
        install -Dm444 "$icon" "$out/share/icons/hicolor/512x512/apps/openchamber-gui.$ext"
      done
    '';
  meta = {
    description = "OpenChamber desktop GUI (Electron AppImage)";
    homepage = "https://github.com/openchamber/openchamber";
    license = lib.licenses.mit;
    mainProgram = "openchamber-gui";
    platforms = [ system ];
  };
}
