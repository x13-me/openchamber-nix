# NixOS module: `services.openchamber`.
#
# Self-contained: the flake's overlay is bundled via `nixpkgs.overlays`
# below, so a single import suffices:
#
# ```nix
# {
#   imports = [ inputs.openchamber-nix.nixosModules.default ];
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
  versions = import ../../versions.nix;
  jsonFormat = pkgs.formats.json { };
  # Runnable server: the configured `package` rebuilt against
  # `opencodePackage`, so the managed binary on the wrapper's PATH tracks
  # the option instead of the wrapper's build-time nixpkgs pin. A fully
  # custom `package` must accept the same `opencode` callPackage argument
  # (see `packages/openchamber-server/package.nix`) — evaluation fails
  # fast otherwise.
  serverPackage = cfg.package.override { opencode = cfg.opencodePackage; };
  # True while the service runs as the auto-created system account (see
  # the `user`/`group` assertion below: both stay at, or both leave, the
  # default together). Only then does the module force HOME/XDG/data paths
  # under `dataDir`; a custom login `user` inherits that account's HOME.
  isSystemUser = cfg.user == "openchamber";
  # Effective bind address: `lan` mirrors upstream `serve --lan`, which only
  # fills in when no explicit `--host` is given (`bin/lib/cli-args.js:543`:
  # `if (options.lan && typeof options.host !== 'string') host = '0.0.0.0'`)
  # — i.e. a loopback-default `host` becomes `0.0.0.0`, an explicitly
  # customized `host` wins.
  effectiveHost = if cfg.lan && cfg.host == "127.0.0.1" then "0.0.0.0" else cfg.host;
  # Loopback forms, mirroring upstream `isLoopbackBindHost`
  # (`server/lib/security/bind-host.js:24`: `localhost`, numeric `127/8`
  # via `isLoopbackIpv4`, `::1` after bracket-strip/lowercase; anything
  # else is network-exposed and needs UI auth — see assertion below).
  # `127.0.0.1` stays listed explicitly for readability; the regex covers
  # the rest of numeric `127/8` the way `net.isIP(...) === 4` does
  # (so `127.foo` is NOT loopback here, matching upstream's refusal).
  # Each octet is a strict 0-255 class so `127.0.0.999` is NOT loopback.
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
    || builtins.match "127(\\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)){1,3}" normalized != null;
  # True while the service account is defined in this evaluation (either
  # the auto-created `openchamber` system account or a declared login
  # user). An externally-managed account (LDAP/SSSD) is unknown here —
  # tmpfiles and user-package wiring must not assume it.
  accountDefined =
    let
      account = config.users.users.${cfg.user} or null;
    in
    isSystemUser || (account != null && (account.isNormalUser || account.isSystemUser));
  # Raw `serve` argv, shared by the direct ExecStart and the
  # password-wrapper below so both stay in sync. `--lan` is passed only
  # when `host` is at its loopback default — mirroring upstream
  # (`cli-args.js:543` ignores `--lan` under an explicit `--host`, and
  # `--host` always carries the effective address here anyway).
  serveArgs = [
    "${serverPackage}/bin/openchamber"
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
  ++ lib.optionals (cfg.lan && cfg.host == "127.0.0.1") [ "--lan" ]
  ++ lib.optionals (!cfg.enableWebUI) [ "--api-only" ];
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

    # NOTE: `mkEnableOption` defaults to false and so does this: the
    # service is headless API-only out of the box, and the browser UI is
    # opt-in (`enable*` naming matches the repo's existing bools).
    enableWebUI = lib.mkOption {
      type = lib.types.bool;
      default = false;
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

    opencodePackage = openchamberLib.mkOpencodePackageOption {
      # `opencode` is intentionally NOT resolved via the throwing
      # `requirePackage` below: the injected flake scope never carries it,
      # so fall back to nixpkgs (an injected scope that DOES carry it —
      # e.g. a pinned overlay set — still wins).
      default = extpkgs.opencode or pkgs.opencode;
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = requirePackage "openchamber-server";
      defaultText = lib.literalExpression "pkgs.openchamber-server";
      description = ''
        The openchamber-server package to run (provided by this flake's overlay, or `_module.args.extpkgs`).

        A custom replacement must accept an `opencode` callPackage
        argument like the default (`packages/openchamber-server/package.nix`):
        the module runs `package.override { opencode = opencodePackage; }`,
        so only the stock interface picks up the managed-binary pin.
      '';
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

        With a custom login user, service state (opencode config/auth,
        `~/.config/openchamber`) lives in that account's real HOME and is
        shared with any personal opencode use on the same account.
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

  config = lib.mkMerge [
    {
      # Bundle the flake's overlay so consumers need only this import.
      # Imported by relative path (not via flake `self`) to avoid
      # self-reference cycles. `overlays.default` remains exposed for manual use.
      nixpkgs.overlays = [ (import ../../nix/overlay.nix) ];
    }
    {
      # Managed-binary drift is advisory only: warn (never assert) when
      # the configured binary's version differs from the
      # upstream-expected one, so a lagging nixpkgs keeps evaluating.
      warnings =
        let
          actualOpencodeVersion = cfg.opencodePackage.version or null;
        in
        lib.optionals (actualOpencodeVersion != null && actualOpencodeVersion != versions.opencodeVersion) [
          "services.openchamber: opencodePackage version ${actualOpencodeVersion} differs from ${versions.opencodeVersion} expected by openchamber-server ${versions.version} (upstream packages/web @opencode-ai/sdk pin) — the managed OpenCode may drift; override services.openchamber.opencodePackage with a matching build, or wait for nixpkgs to catch up."
        ];
    }
    (lib.mkIf cfg.enable (
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
              # Mirrors upstream `assertAuthenticatedNetworkExposure`
              # (`bin/lib/cli-network.js:156`, enforced CLI-side at
              # `bin/lib/commands-serve.js:120` and server-side at
              # `server/index.js:1625` with the same two escape hatches:
              # a configured UI password or
              # `OPENCHAMBER_ALLOW_UNAUTHENTICATED_LAN=true`): a
              # network-exposed bind without either throws upstream —
              # catch it at evaluation instead. `uiPasswordFile` counts
              # because the wrapper below exports its content as
              # `OPENCHAMBER_UI_PASSWORD` (upstream's real mechanism —
              # there is no `*_PASSWORD_FILE` var at the pinned rev).
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
              assertion = isSystemUser || !cfg.installCliForUser || accountDefined;
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
              packages = lib.optionals cfg.installCliForUser [ serverPackage ];
            };
          };
          users.groups = lib.mkIf (cfg.group == "openchamber") {
            openchamber = { };
          };

          # A custom `dataDir` outside `/var/lib/openchamber` is not covered
          # by `StateDirectory` below — create it before start while the
          # service account is known to this evaluation. An
          # externally-managed account (LDAP/SSSD, ...) must pre-create the
          # directory itself with correct ownership (see `dataDir` docs).
          # Paths at or under `/var/lib/openchamber` are already owned via
          # `StateDirectory`, so no redundant rule (covers `.../sub` too).
          systemd.tmpfiles.rules =
            let
              dataDirStr = toString cfg.dataDir;
              underStateDir =
                dataDirStr == "/var/lib/openchamber" || lib.hasPrefix "/var/lib/openchamber/" dataDirStr;
            in
            lib.mkIf (!underStateDir && accountDefined) [
              "d ${dataDirStr} 0750 ${cfg.user} ${cfg.group} -"
            ];

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
              # Strict `=== 'true'` comparison upstream
              # (`server/lib/security/bind-host.js:35`) — no `1` shorthand.
              OPENCHAMBER_ALLOW_UNAUTHENTICATED_LAN = "true";
            }
            // lib.optionalAttrs (cfg.opencodeHost != null) {
              OPENCODE_HOST = cfg.opencodeHost;
            }
            // lib.optionalAttrs (cfg.opencodePort != null) {
              OPENCODE_PORT = toString cfg.opencodePort;
            }
            // lib.optionalAttrs cfg.skipOpencodeStart {
              # Server checks both with strict `=== 'true'`
              # (`server/index.js:641`; the serve launcher itself forwards
              # one into the other at `bin/lib/commands-serve.js:291).
              # Setting both is harmless (same flag/env pairing pattern as
              # `--api-only`).
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
            };
            serviceConfig = {
              ExecStart =
                if cfg.uiPasswordFile == null then
                  lib.escapeShellArgs serveArgs
                else
                  # Upstream reads only `--ui-password` /
                  # `OPENCHAMBER_UI_PASSWORD` (`bin/lib/cli-args.js:61`,
                  # `server/index.js:1622`) — no `*_FILE` var exists, so the
                  # LoadCredential-staged secret is exported into the real
                  # env var here. A wrapper (not `EnvironmentFile`) keeps
                  # the secret out of the world-readable store and out of
                  # `/proc` cmdlines (`--ui-password` on argv would leak).
                  # Fails fast on an empty credential instead of serving
                  # an unprotected network bind.
                  "${pkgs.writeShellScript "openchamber-serve" ''
                    set -euo pipefail
                    credential="$CREDENTIALS_DIRECTORY/ui-password"
                    if [ ! -s "$credential" ]; then
                      echo "openchamber: UI password credential is empty or missing: $credential" >&2
                      exit 1
                    fi
                    export OPENCHAMBER_UI_PASSWORD="$(cat "$credential")"
                    exec ${lib.escapeShellArgs serveArgs}
                  ''}";
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
          users.users.${cfg.user}.packages = [ serverPackage ];
        })
        (lib.mkIf (cfg.settings != { }) (
          let
            settingsFile = jsonFormat.generate "openchamber-settings.json" cfg.settings;
          in
          {
            # Freeform settings (default `{}` = this block vanishes, behavior
            # unchanged). Upstream has no settings env var or `serve` flag —
            # the live document is `$OPENCHAMBER_DATA_DIR/settings.json`
            # (`server/index.js:320`, rooted at `OPENCHAMBER_DATA_DIR` or
            # `~/.config/openchamber`), so seed it before start — but ONLY
            # when absent or empty (`[ ! -s ... ]`). An existing file is
            # never touched: edits made through the running UI (or by hand)
            # survive every (re)start. Runs as the service user, so `$HOME`
            # resolves for personal-user instances while
            # `OPENCHAMBER_DATA_DIR` covers the default system user. To
            # re-apply Nix `settings`, delete the file (or empty it) and
            # restart: the next start re-seeds it from the store copy.
            # NOTE: the store copy is world-readable — never put secrets in
            # `settings`; use `uiPasswordFile` / credentials for secrets.
            systemd.services.openchamber.serviceConfig.ExecStartPre = [
              "${pkgs.writeShellScript "openchamber-install-settings" ''
                set -euo pipefail
                dest="''${OPENCHAMBER_DATA_DIR:-$HOME/.config/openchamber}/settings.json"
                mkdir -p "$(dirname "$dest")"
                if [ ! -s "$dest" ]; then
                  cp -f ${settingsFile} "$dest"
                  chmod 0600 "$dest"
                fi
              ''}"
            ];
          }
        ))
      ]
    ))
  ];
}
