# Home Manager module: `programs.openchamber-gui` + `programs.openchamber-server`.
#
# Self-contained: the flake's overlay is bundled via `nixpkgs.overlays`
# below, so a single import suffices:
#
# ```nix
# {
#   imports = [ inputs.openchamber-nix.homeManagerModules.default ];
#   programs.openchamber-gui.enable = true;
#   programs.openchamber-server.enable = true; # ad-hoc `openchamber serve`
# }
# ```
{
  config,
  lib,
  pkgs,
  ...
}:
let
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
  cfg = config.programs.openchamber-gui;
in
{
  _class = "homeManager";
  _file = ./default.nix;

  options.programs.openchamber-gui = {
    enable = lib.mkEnableOption "OpenChamber desktop GUI";

    package = lib.mkOption {
      type = lib.types.package;
      default = requirePackage "openchamber-gui";
      defaultText = lib.literalExpression "pkgs.openchamber-gui";
      description = "The openchamber-gui package to install (provided by this flake's overlay, or `_module.args.extpkgs`).";
    };
    # NOTE: no keep-sorted markers on this set on purpose — keep-sorted
    # sorts raw lines and would scramble multi-line option definitions.
  };

  options.programs.openchamber-server = {
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
    (lib.mkIf cfg.enable {
      home.packages = [ cfg.package ];
    })
    (lib.mkIf config.programs.openchamber-server.enable {
      home.packages = [ config.programs.openchamber-server.package ];
    })
  ];
}
