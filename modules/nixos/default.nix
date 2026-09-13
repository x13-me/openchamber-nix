# NixOS module: `services.openchamber`.
#
# Consuming flake inputs need the overlay (or `_module.args.extpkgs`):
#
# ```nix
# {
#   imports = [ inputs.openchamber-nix.nixosModules.default ];
#   nixpkgs.overlays = [ inputs.openchamber-nix.overlays.default ];
#   services.openchamber = {
#     enable = true;
#     port = 3000;
#   };
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
  # module of the same evaluation (e.g. next to the `imports` entry below);
  # falls back to the overlay package otherwise.
  # NOTE: read via `config._module.args`, not an `@args` capture — extra
  # module args only reach *named* formals (see `applyModuleArgs`), so an
  # `@args` capture would silently miss the injection.
  extpkgs = config._module.args.extpkgs or pkgs;
  cfg = config.services.openchamber;
  jsonFormat = pkgs.formats.json { };
  settingsFile = jsonFormat.generate "openchamber-settings.json" cfg.settings;
in
{
  _class = "nixos";
  _file = ./default.nix;

  imports = [
    # keep-sorted start
    ../generic/settings.nix
    # keep-sorted end
  ];

  options.services.openchamber = {
    enable = lib.mkEnableOption "OpenChamber server";

    host = openchamberLib.mkHostOption { };

    package = lib.mkOption {
      type = lib.types.package;
      default = extpkgs.openchamber-server;
      defaultText = lib.literalExpression "pkgs.openchamber-server";
      description = "The openchamber-server package to run (provided by this flake's overlay, or `_module.args.extpkgs`).";
    };

    port = openchamberLib.mkPortOption { };

    uiPasswordFile = openchamberLib.mkPasswordFileOption { };
    # NOTE: `settings` comes from `modules/generic/settings.nix` (imported
    # above). No keep-sorted markers on this set on purpose — keep-sorted
    # sorts raw lines and would scramble multi-line option definitions.
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        systemd.services.openchamber = {
          description = "OpenChamber server";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          environment = {
            OPENCHAMBER_HOST = cfg.host;
            OPENCHAMBER_PORT = toString cfg.port;
          }
          // lib.optionalAttrs (cfg.uiPasswordFile != null) {
            # Staged via LoadCredential below so it stays readable under DynamicUser.
            OPENCHAMBER_UI_PASSWORD_FILE = "/run/credentials/openchamber.service/ui-password";
          };
          serviceConfig = {
            ExecStart = lib.escapeShellArgs [
              "${cfg.package}/bin/openchamber"
              "serve"
              "--host"
              cfg.host
              "--port"
              (toString cfg.port)
            ];
            Restart = "on-failure";
            DynamicUser = true;
            StateDirectory = "openchamber";
          }
          // lib.optionalAttrs (cfg.uiPasswordFile != null) {
            # LoadCredential stages the secret where DynamicUser can read
            # it; the raw host path (e.g. /run/secrets) may not be
            # accessible to the sandboxed service user otherwise.
            LoadCredential = [ "ui-password:${cfg.uiPasswordFile}" ];
          };
        };
      }
      (lib.mkIf (cfg.settings != { }) {
        # Freeform settings (default `{}` = this block vanishes, behavior
        # unchanged). Confirm the exact flag/env contract against
        # `openchamber serve --help` for your pinned version; the JSON
        # file path itself is stable.
        environment.etc."openchamber/settings.json".source = settingsFile;
        systemd.services.openchamber.environment.OPENCHAMBER_SETTINGS_FILE =
          "/etc/openchamber/settings.json";
      })
    ]
  );
}
