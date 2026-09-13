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
  # True while the service runs as the auto-created system account (see
  # the `user`/`group` assertion below: both stay at, or both leave, the
  # default together). Only then does the module force HOME/XDG/data paths
  # under `dataDir`; a custom login `user` inherits that account's HOME.
  isSystemUser = cfg.user == "openchamber";
  # Effective bind address: `lan` mirrors upstream `serve --lan`, which only
  # fills in when no explicit `--host` is given — i.e. a loopback-default
  # `host` becomes `0.0.0.0`, an explicitly customized `host` wins.
  effectiveHost = if cfg.lan && cfg.host == "127.0.0.1" then "0.0.0.0" else cfg.host;
  # Loopback forms, mirroring upstream `isLoopbackBindHost` (localhost,
  # 127/8, ::1, bracketed ::1) for the common spellings; anything else is
  # treated as network-exposed and needs UI auth (see assertion below).
  isLoopbackHost =
    let
      normalized = lib.toLower effectiveHost;
    in
    builtins.elem normalized [
      "127.0.0.1"
      "localhost"
      "::1"
      "[::1]"
    ]
    || lib.hasPrefix "127." normalized;
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

    # NOTE: `mkEnableOption` defaults to false; the web UI stays on unless
    # opted out, so this is a plain bool defaulting to true (`enable*`
    # naming matches the repo's existing bools).
    enableWebUI = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to serve the builtin browser web UI alongside the API.

        When disabled, `openchamber serve` starts in API-only mode: the
        service passes `--api-only` on the command line and sets
        `OPENCHAMBER_API_ONLY=1` in the environment. Both are honored by
        the pinned upstream (either alone would suffice; setting both is
        harmless — upstream itself forwards one into the other). Browser
        UI assets are not served; API routes stay available.
      '';
    };

    allowUnauthenticatedLan = openchamberLib.mkAllowUnauthenticatedLanOption { };

    chatsDir = openchamberLib.mkChatsDirOption { };

    dataDir = openchamberLib.mkDataDirOption { };

    host = openchamberLib.mkHostOption { };

    installCliForUser = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to install the configured `package` into the service
        account's user packages (`users.users.<user>.packages`), putting
        the `openchamber` CLI on that account's PATH for pairing and
        management commands (`openchamber status`, `openchamber tunnel`,
        ...).

        Disable this when `user` is managed outside this evaluation
        (LDAP/SSSD, ...): assigning `users.users.<name>.packages`
        unconditionally would otherwise implicitly CREATE a local account
        shadowing the external one. Such accounts get the CLI via
        `nix profile install` / explicit PATH instead.
      '';
    };

    lan = openchamberLib.mkLanOption { };

    opencodeHost = openchamberLib.mkOpencodeHostOption { };

    opencodeHostname = openchamberLib.mkOpencodeHostnameOption { };

    opencodePort = openchamberLib.mkOpencodePortOption { };

    package = lib.mkOption {
      type = lib.types.package;
      default = requirePackage "openchamber-server";
      defaultText = lib.literalExpression "pkgs.openchamber-server";
      description = "The openchamber-server package to run (provided by this flake's overlay, or `_module.args.extpkgs`).";
    };

    port = openchamberLib.mkPortOption { };

    skipApiCompression = openchamberLib.mkSkipApiCompressionOption { };

    skipOpencodeStart = openchamberLib.mkSkipOpencodeStartOption { };

    uiPasswordFile = openchamberLib.mkPasswordFileOption { };

    verboseRequestLogs = openchamberLib.mkVerboseRequestLogsOption { };

    user = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "openchamber";
      example = "alice";
      description = ''
        User the service runs as.

        When left at the default, a system user is created automatically.
        Set it to an existing login user (e.g. your own account) to give
        the server direct access to that user's HOME, ~/.ssh, git config,
        and workspace files — the service wraps opencode/git/openssh and
        needs real filesystem access, so it must not run isolated.

        Must be customized together with `group` (see also `group`):
        e.g. `user = "alice"` requires `group = "users"`.
      '';
    };

    group = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "openchamber";
      example = "users";
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
        # Fail fast when only one of `user`/`group` leaves the default:
        # a half-customized identity would run the service under a
        # nonexistent or mismatched account.
        assertions = [
          {
            assertion = isSystemUser == (cfg.group == "openchamber");
            message = ''services.openchamber: `user` and `group` must be set together — e.g. user = "alice" requires group = "users" (keep both at "openchamber" or customize both).'';
          }
          {
            # Mirrors upstream `assertAuthenticatedNetworkExposure`: a
            # network-exposed bind without a UI password throws
            # AUTH_CONFIG_ERROR at startup — catch it at evaluation instead.
            assertion = isLoopbackHost || cfg.uiPasswordFile != null || cfg.allowUnauthenticatedLan;
            message = ''services.openchamber: host "${effectiveHost}" is reachable on the network — set `uiPasswordFile` (recommended) or `allowUnauthenticatedLan = true` to accept the risk (upstream refuses to bind without UI auth).'';
          }
          {
            # Fail fast when a custom `user` names an account this
            # evaluation never defines (e.g. LDAP/SSSD): installing CLI
            # packages would otherwise implicitly create a local shadow
            # account (or trip nixpkgs' own user-completion assertions).
            # Either define the account (the `alice`/`users` case) or opt
            # out with `installCliForUser = false`.
            # NOTE: reading the merged account VALUE here is safe — only
            # gating a `users.users` key on it would recurse.
            assertion =
              let
                account = config.users.users.${cfg.user} or null;
                accountDefined = account != null && (account.isNormalUser || account.isSystemUser);
              in
              isSystemUser || !cfg.installCliForUser || accountDefined;
            message = ''services.openchamber: user "${cfg.user}" is not defined in this evaluation — define it (e.g. users.users."${cfg.user}".isNormalUser = true) or set `installCliForUser = false` when the account is managed externally (LDAP/SSSD).'';
          }
        ];

        # Static service account (created only while the defaults are
        # used). A custom `user`/`group` must already exist — e.g. point
        # `user` at your login account so the server can reach HOME,
        # ~/.ssh, git config, and workspace files.
        users.users = lib.mkIf isSystemUser {
          openchamber = {
            isSystemUser = true;
            inherit (cfg) group;
            description = "OpenChamber server";
            # CLI on PATH for the default account (pairing/management).
            packages = lib.optionals cfg.installCliForUser [ cfg.package ];
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
            OPENCHAMBER_HOST = effectiveHost;
            OPENCHAMBER_PORT = toString cfg.port;
            # Always explicit: matches the upstream default (`127.0.0.1`)
            # so managed-OpenCode binds stay deterministic.
            OPENCHAMBER_OPENCODE_HOSTNAME = cfg.opencodeHostname;
          }
          // lib.optionalAttrs (!cfg.enableWebUI) {
            # API-only fallback env (the `--api-only` CLI flag in ExecStart
            # below is the primary switch; both are honored by the pinned
            # upstream 1.23.0 — `--api-only` in `serve` arg parsing plus
            # `OPENCHAMBER_API_ONLY` (`1`/`true`) in the server entrypoint).
            OPENCHAMBER_API_ONLY = "1";
          }
          // lib.optionalAttrs (cfg.chatsDir != null) {
            OPENCHAMBER_CHATS_DIR = toString cfg.chatsDir;
          }
          // lib.optionalAttrs cfg.allowUnauthenticatedLan {
            # Strict `=== 'true'` comparison upstream — no `1` shorthand.
            OPENCHAMBER_ALLOW_UNAUTHENTICATED_LAN = "true";
          }
          // lib.optionalAttrs (cfg.opencodeHost != null) {
            OPENCODE_HOST = cfg.opencodeHost;
          }
          // lib.optionalAttrs (cfg.opencodePort != null) {
            OPENCODE_PORT = toString cfg.opencodePort;
          }
          // lib.optionalAttrs cfg.skipOpencodeStart {
            # Server checks both with strict `=== 'true'`; setting both is
            # harmless (same flag/env pairing pattern as `--api-only`).
            OPENCODE_SKIP_START = "true";
            OPENCHAMBER_SKIP_OPENCODE_START = "true";
          }
          // lib.optionalAttrs cfg.verboseRequestLogs {
            OPENCHAMBER_VERBOSE_REQUEST_LOGS = "1";
          }
          // lib.optionalAttrs cfg.skipApiCompression {
            OPENCHAMBER_SKIP_API_COMPRESSION = "1";
          }
          // lib.optionalAttrs isSystemUser {
            # Writable pathing for the default system account: systemd
            # starts system users with a bare environment, and
            # StateDirectory alone only creates /var/lib/openchamber
            # without pointing HOME/XDG at it — upstream would then resolve
            # its data dir (`$HOME/.config/openchamber` unless
            # OPENCHAMBER_DATA_DIR is set) to nowhere writable. Force the
            # whole HOME/XDG tree plus OPENCHAMBER_DATA_DIR under `dataDir`.
            # Skipped for a custom login `user` so personal-user instances
            # inherit that account's HOME (`~/.config/openchamber` etc.).
            HOME = "${cfg.dataDir}";
            XDG_CONFIG_HOME = "${cfg.dataDir}/.config";
            XDG_DATA_HOME = "${cfg.dataDir}/.local/share";
            XDG_STATE_HOME = "${cfg.dataDir}/.local/state";
            XDG_CACHE_HOME = "${cfg.dataDir}/.cache";
            OPENCHAMBER_DATA_DIR = "${cfg.dataDir}/.config/openchamber";
          }
          // lib.optionalAttrs (cfg.uiPasswordFile != null) {
            # Staged via LoadCredential below so the service never needs
            # direct read access to the raw host path (e.g. /run/secrets).
            OPENCHAMBER_UI_PASSWORD_FILE = "/run/credentials/openchamber.service/ui-password";
          };
          serviceConfig = {
            ExecStart = lib.escapeShellArgs (
              [
                "${cfg.package}/bin/openchamber"
                "serve"
                # Foreground is mandatory under systemd (`Type=simple`
                # tracks the direct child): without it `serve` daemonizes
                # and the service would go inactive right after start.
                # Upstream documents `--foreground` for exactly this setup.
                "--foreground"
                "--host"
                effectiveHost
                "--port"
                (toString cfg.port)
              ]
              ++ lib.optionals cfg.lan [ "--lan" ]
              ++ lib.optionals (!cfg.enableWebUI) [ "--api-only" ]
            );
            Restart = "on-failure";
            User = cfg.user;
            Group = cfg.group;
            # Owned by User:Group; keeps state across upgrades.
            StateDirectory = "openchamber";
            # Upstream resolves its data dir from HOME/XDG (or
            # OPENCHAMBER_DATA_DIR above); give the server a real writable
            # cwd instead of systemd's `/` default, and allow writes there.
            WorkingDirectory = cfg.dataDir;
            ReadWritePaths = [ cfg.dataDir ];
          }
          // lib.optionalAttrs (cfg.uiPasswordFile != null) {
            # LoadCredential stages the secret where the static service
            # user can read it; the raw host path may not be accessible
            # to it otherwise.
            LoadCredential = [ "ui-password:${cfg.uiPasswordFile}" ];
          };
        };
      }
      # CLI on PATH for a custom service account (pairing/management
      # commands like `openchamber status` / `openchamber tunnel` run as
      # the service user). Gated on static conditions only: testing
      # `users.users` for the account here would recurse infinitely (the
      # merge cannot decide its own key set), so an externally-managed
      # account (LDAP/SSSD) must opt out via `installCliForUser = false`
      # instead — see that option.
      (lib.mkIf (cfg.installCliForUser && !isSystemUser) {
        users.users.${cfg.user}.packages = [ cfg.package ];
      })
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
