# OpenChamber desktop GUI: upstream Linux AppImage repackaged with
# `appimageTools.wrapType2`, desktop entry `Exec`/`Icon` fixed, icons installed.
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
      sed -i 's|^Exec=AppRun[^ ]*|Exec=openchamber-gui|' $out/share/applications/*.desktop
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
      # Upstream declares `Icon=openchamber`, but the only copy installed
      # under that name lands in the non-standard `hicolor/1024x1024` dir,
      # which hicolor's index.theme does not list — so theme lookups never
      # match it and the AppMenu shows a placeholder. The copy in the
      # standard `512x512` dir instead uses our `openchamber-gui` name,
      # which no desktop file references. Install BOTH names in the
      # standard dir and point the known entry at the name we guarantee.
      # Any other Icon= lines (e.g. from additional upstream .desktop
      # files) are left untouched and keep resolving via the
      # usr/share/icons copy above.
      for guiIcon in $out/share/icons/hicolor/512x512/apps/openchamber-gui.*; do
        [ -f "$guiIcon" ] || continue
        ext="''${guiIcon##*.}"
        install -Dm444 "$guiIcon" "$out/share/icons/hicolor/512x512/apps/openchamber.$ext"
      done
      if ls $out/share/icons/hicolor/512x512/apps/openchamber-gui.* >/dev/null 2>&1; then
        sed -i 's|^Icon=openchamber$|Icon=openchamber-gui|' $out/share/applications/*.desktop
      fi
      # Fail-safe, not fail-hard: warn if any installed entry still names
      # an icon we do not ship, so future upstream renames surface at
      # build time instead of as a silent placeholder in the AppMenu.
      for desktop in $out/share/applications/*.desktop; do
        iconName="$(sed -n 's|^Icon=||p' "$desktop" | head -n 1)"
        case "$iconName" in "" | /* | *.*) continue ;; esac
        match="$(find $out/share/icons $out/share/pixmaps -name "$iconName.*" -print -quit 2>/dev/null)"
        [ -n "$match" ] || echo "warning: $desktop: Icon=$iconName has no installed file" >&2
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
