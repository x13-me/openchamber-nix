# OpenChamber desktop GUI: upstream Linux AppImage repackaged with
# `appimageTools.wrapType2`, desktop entry `Exec`/`Icon` fixed,
# multi-size hicolor icons rendered from the upstream master PNG.
#
# NOTE: electron-updater self-update is disabled by design here —
# the AppImage lives in the immutable Nix store.
{
  lib,
  stdenv,
  fetchurl,
  appimageTools,
  imagemagick,
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
  # ImageMagick renders the multi-size hicolor icons below. It reaches
  # `extraInstallCommands` because `wrapType2 → buildFHSEnv` forwards
  # `nativeBuildInputs` to the final `stdenvNoCC.mkDerivation`.
  nativeBuildInputs = [ imagemagick ];
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
      for icon in ${extracted}/*.svg; do
        [ -f "$icon" ] || continue
        # SVGs belong in `scalable/`, not a fixed-pixel dir.
        install -Dm444 "$icon" "$out/share/icons/hicolor/scalable/apps/openchamber-gui.svg"
        install -Dm444 "$icon" "$out/share/icons/hicolor/scalable/apps/openchamber.svg"
      done
      # Multi-size hicolor icons, rendered from the largest upstream PNG.
      # A lone 512x512 entry is fragile: menu/panel launchers request
      # small sizes (16-48px) and fall back unreliably to a single large
      # icon — and the AppImage root PNG is actually 1024x1024, so a raw
      # copy into the 512x512 dir is also a nominal/actual size mismatch.
      # Render every standard size instead, under BOTH names (the
      # `openchamber-gui` name our .desktop points at, plus the upstream
      # `openchamber` name any other entry may reference).
      if command -v magick >/dev/null 2>&1; then
        magickCmd="magick"
      elif command -v convert >/dev/null 2>&1; then
        magickCmd="convert"
      else
        echo "error: openchamber-gui: neither magick nor convert on PATH (imagemagick missing from nativeBuildInputs)" >&2
        exit 1
      fi
      # `magick identify` (v7) vs standalone `identify` (v6/compat).
      if "$magickCmd" identify -version >/dev/null 2>&1; then
        identifyCmd="$magickCmd identify"
      else
        identifyCmd="identify"
      fi
      srcIcon=""
      srcPixels=0
      for candidate in ${extracted}/*.png "$out"/share/icons/hicolor/*/apps/*.png; do
        [ -f "$candidate" ] || continue
        dims="$($identifyCmd -format "%w %h" "$candidate" 2>/dev/null)" || continue
        width="''${dims%% *}"
        height="''${dims##* }"
        if [ -z "$width" ] || [ -z "$height" ]; then continue; fi
        case "$width$height" in *[!0-9]*) continue ;; esac
        pixels=$(( width * height ))
        if [ "$pixels" -gt "$srcPixels" ]; then
          srcPixels="$pixels"
          srcIcon="$candidate"
        fi
      done
      if [ -z "$srcIcon" ]; then
        echo "error: openchamber-gui: no source PNG icon found in ${extracted}" >&2
        exit 1
      fi
      for size in 16 22 24 32 48 64 128 256 512; do
        for iconName in openchamber-gui openchamber; do
          dest="$out/share/icons/hicolor/''${size}x''${size}/apps/''${iconName}.png"
          mkdir -p "$(dirname "$dest")"
          "$magickCmd" "$srcIcon" -resize "''${size}x''${size}" -strip "$dest"
          chmod 444 "$dest"
        done
      done
      # Pixmap fallback: several launchers consult `share/pixmaps` when
      # the theme lookup misses — ship both names there as well.
      for iconName in openchamber-gui openchamber; do
        install -Dm444 "$srcIcon" "$out/share/pixmaps/''${iconName}.png"
      done
      # Upstream declares `Icon=openchamber`; point the known entry at
      # the `openchamber-gui` name we guarantee at every size. Both names
      # are installed everywhere, so any other entry keeping
      # `Icon=openchamber` still resolves.
      if [ -f "$out/share/icons/hicolor/48x48/apps/openchamber-gui.png" ]; then
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
