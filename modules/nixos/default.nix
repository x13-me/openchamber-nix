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
  requirePackage =
    name:
    if builtins.hasAttr name extpkgs then
      extpkgs.${name}
    else
      throw "openchamber-nix: `${name}` not found — apply the overlay (`nixpkgs.overlays = [ inputs.openchamber-nix.overlays.default ];`) or inject the flake package set (`_module.args.extpkgs = inputs.openchamber-nix.legacyPackages.\${pkgs.stdenv.hostPlatform.system};`).";
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
      default = requirePackage "openchamber-server";
      defaultText = lib.literalExpression "pkgs.openchamber-server";
      description = "The openchamber-server package to run (provided by this flake's overlay, or `_module.args.extpkgs`).";
    };

    port = openchamberLib.mkPortOption { };

    uiPasswordFile = openchamberLib.mkPasswordFileOption { };

    user = lib.mkOption {
      type = lib.types.str;
      default = "openchamber";
      description = ''
        User the service runs as.

        When left at the default, a system user is created automatically.
        Set it to an existing login user (e.g. your own account) to give
        the server direct access to that user's HOME, ~/.ssh, git config,
        and workspace files — the service wraps opencode/git/openssh and
        needs real filesystem access, so it must not run isolated.
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "openchamber";
      description = ''
        Group the service runs as.

        When left at the default, the group is created automatically.
        When customizing `user` to an existing account, set this to that
        account's primary group (commonly `users`) and manage the group
        yourself.
      '';
    };
    # NOTE: `settings` comes from `modules/generic/settings.nix` (imported
    # above). No keep-sorted markers on this set on purpose — keep-sorted
    # sorts raw lines and would scramble multi-line option definitions.
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        # Static service account (created only while the defaults are
        # used). A custom `user`/`group` must already exist — e.g. point
        # `user` at your login account so the server can reach HOME,
        # ~/.ssh, git config, and workspace files.
        users.users = lib.mkIf (cfg.user == "openchamber") {
          openchamber = {
            isSystemUser = true;
            inherit (cfg) group;
            description = "OpenChamber server";
          };
        };
        users.groups = lib.mkIf (cfg.group == "openchamber") {
          openchamber = { };
        };

        systemd.services.openchamber = {
          description = "OpenChamber server";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          environment = {
            OPENCHAMBER_HOST = cfg.host;
            OPENCHAMBER_PORT = toString cfg.port;
          }
          // lib.optionalAttrs (cfg.uiPasswordFile != null) {
            # Staged via LoadCredential below so the service never needs
            # direct read access to the raw host path (e.g. /run/secrets).
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
            User = cfg.user;
            Group = cfg.group;
            # Owned by User:Group; keeps state across upgrades.
            StateDirectory = "openchamber";
          }
          // lib.optionalAttrs (cfg.uiPasswordFile != null) {
            # LoadCredential stages the secret where the static service
            # user can read it; the raw host path may not be accessible
            # to it otherwise.
            LoadCredential = [ "ui-password:${cfg.uiPasswordFile}" ];
          };
        };
      }
      (lib.mkIf (cfg.settings != { }) (
        let
          settingsFile = jsonFormat.generate "openchamber-settings.json" cfg.settings;
        in
        {
          # Freeform settings (default `{}` = this block vanishes, behavior
          # unchanged). Confirm the exact flag/env contract against
          # `openchamber serve --help` for your pinned version; the JSON
          # file path itself is stable.
          # NOTE: the store copy is world-readable — never put secrets in
          # `settings`; use `uiPasswordFile` / credentials for secrets.
          environment.etc."openchamber/settings.json" = {
            source = settingsFile;
            mode = "0440";
          };
          systemd.services.openchamber.environment.OPENCHAMBER_SETTINGS_FILE =
            "/etc/openchamber/settings.json";
        }
      ))
    ]
  );
}
