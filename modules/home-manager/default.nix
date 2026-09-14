# Home Manager module: `programs.openchamber` (`gui` + `server`).
#
# Self-contained: the flake's overlay is bundled via `nixpkgs.overlays`
# below, so a single import suffices:
#
# ```nix
# {
#   imports = [ inputs.openchamber-nix.homeManagerModules.default ];
#   programs.openchamber.gui.enable = true;
#   programs.openchamber.server.enable = true; # ad-hoc `openchamber serve`
# }
# ```
{
  config,
  lib,
  pkgs,
  ...
}:
let
  openchamberLib = import ../../lib { inherit lib; };
  # Optional flake package set, injected via `_module.args.extpkgs` in any
  # module of the same evaluation; falls back to the overlay package.
  # NOTE: read via `config._module.args`, not an `@args` capture — extra
  # module args only reach *named* formals (see `applyModuleArgs`), so an
  # `@args` capture would silently miss the injection.
  extpkgs = config._module.args.extpkgs or pkgs;
  requirePackage =
    name:
    if builtins.hasAttr name extpkgs then
      extpkgs.${name}
    else
      throw "openchamber-nix: `${name}` not found — apply the overlay (`nixpkgs.overlays = [ inputs.openchamber-nix.overlays.default ];`) or inject the flake package set (`_module.args.extpkgs = inputs.openchamber-nix.legacyPackages.\${pkgs.stdenv.hostPlatform.system};`).";
  cfg = config.programs.openchamber;
  # System service view, present only when home-manager evaluates as a
  # NixOS submodule (which sets `_module.args.osConfig`). The `or null`
  # guard keeps standalone home-manager evaluation working.
  osConfig = config._module.args.osConfig or null;
  osService = if osConfig == null then null else (osConfig.services or { }).openchamber or null;
  osServiceEnabled = osService != null && (osService.enable or false);
  # Auto-point: an explicit `serverUrl` wins; otherwise follow the enabled
  # system service; otherwise none (plain unwrapped install, current
  # behavior).
  autoServerUrl =
    if !osServiceEnabled then
      null
    else
      openchamberLib.guiServerUrlFromService {
        host = osService.host or "127.0.0.1";
        lan = osService.lan or false;
        port = osService.port or 3000;
      };
  effectiveServerUrl = if cfg.gui.serverUrl != null then cfg.gui.serverUrl else autoServerUrl;
  # Upstream `packages/electron/main.mjs` at the pinned rev
  # (`v1.23.0/d073858`): `:1436-1439` skips the bundled local server when
  # `OPENCHAMBER_SKIP_LOCAL_SERVER` is set, `:2984-3034` overrides the
  # connection target from `OPENCHAMBER_SERVER_URL`. Undocumented
  # upstream — see the `serverUrl` option description. `wrapType2` outputs
  # a `bin/openchamber-gui` wrapper script already, so env injection goes
  # through an outer `symlinkJoin` + `makeWrapper` layer instead of
  # rebuilding the AppImage repackaging itself. Lazy: only evaluated when
  # `effectiveServerUrl` is non-null (see `home.packages` below), so a
  # null URL never reaches `escapeShellArg`.
  wrappedGuiPackage = pkgs.symlinkJoin {
    name = "openchamber-gui-with-server";
    paths = [ cfg.gui.package ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/openchamber-gui \
        --set OPENCHAMBER_SKIP_LOCAL_SERVER '1' \
        --set OPENCHAMBER_SERVER_URL ${lib.escapeShellArg effectiveServerUrl}
    '';
  };
in
{
  _class = "homeManager";
  _file = ./default.nix;

  options.programs.openchamber.gui = {
    enable = lib.mkEnableOption "OpenChamber desktop GUI";

    package = lib.mkOption {
      type = lib.types.package;
      default = requirePackage "openchamber-gui";
      defaultText = lib.literalExpression "pkgs.openchamber-gui";
      description = "The openchamber-gui package to install (provided by this flake's overlay, or `_module.args.extpkgs`).";
    };

    serverUrl = openchamberLib.mkGuiServerUrlOption { };
    # NOTE: no keep-sorted markers on this set on purpose — keep-sorted
    # sorts raw lines and would scramble multi-line option definitions.
  };

  options.programs.openchamber.server = {
    enable = lib.mkEnableOption "OpenChamber server + CLI (ad-hoc `openchamber serve`)";

    package = lib.mkOption {
      type = lib.types.package;
      default = requirePackage "openchamber-server";
      defaultText = lib.literalExpression "pkgs.openchamber-server";
      description = "The openchamber-server package to install (provided by this flake's overlay, or `_module.args.extpkgs`).";
    };
  };

  config = lib.mkMerge [
    {
      # Bundle the flake's overlay so consumers need only this import.
      # Imported by relative path (not via flake `self`) to avoid
      # self-reference cycles. `overlays.default` remains exposed for manual use.
      nixpkgs.overlays = [ (import ../../nix/overlay.nix) ];
    }
    (lib.mkIf cfg.gui.enable {
      home.packages = [
        (if effectiveServerUrl == null then cfg.gui.package else wrappedGuiPackage)
      ];
    })
    (lib.mkIf cfg.server.enable {
      home.packages = [ cfg.server.package ];
    })
  ];
}
