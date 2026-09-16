# OpenChamber flake helpers, written in nixdoc style (`/** ... */`).
#
# Extensible via `lib.extend` / `makeExtensible`:
#
# ```nix
# myLib = openchamberLib.extend (final: prev: { myHelper = ...; });
# ```
{ lib }:
lib.makeExtensible (_final: {
  /**
    Nix systems this flake builds for.

    Single source of truth: `nix/default.nix` derives `forAllSystems`
    from this list, and package `meta.platforms` mirrors it.
  */
  systems = [
    "x86_64-linux"
    "aarch64-linux"
  ];

  /**
    Map a Nix system to the upstream OpenChamber AppImage arch naming.

    Upstream uses `x86_64` / `arm64` (NOT `aarch64`).

    # Arguments

    - `versions`: the parsed contents of `versions.nix`
      (`systems.<system>.arch`).
    - `system`: e.g. `"x86_64-linux"`.

    Fails fast on unknown systems so a bad matrix entry errors at
    evaluation time, not mid-build.

    # Example

    ```nix
    archOf versions "aarch64-linux" # => "arm64"
    ```
  */
  archOf =
    versions: system:
    versions.systems.${system}.arch or (throw "openchamber-nix: no arch mapping for system ${system}");

  /**
    Standard writable state directory option for `services.openchamber`.

    Backs the systemd `WorkingDirectory` / `ReadWritePaths` wiring and,
    for the default `openchamber` system user, the forced `HOME` / XDG /
    `OPENCHAMBER_DATA_DIR` paths. Personal-user instances (custom `user`)
    inherit the login user's `HOME` instead and ignore this for data
    resolution.

    # Arguments

    - `default`: state directory (defaults to `"/var/lib/openchamber"`).
  */
  mkDataDirOption =
    {
      default ? "/var/lib/openchamber",
    }:
    lib.mkOption {
      type = lib.types.path;
      inherit default;
      description = ''
        Writable state directory for the service (systemd WorkingDirectory
        and ReadWritePaths).

        When running as the default `openchamber` system user, this is also
        the base for the forced HOME, XDG_CONFIG_HOME, XDG_DATA_HOME,
        XDG_STATE_HOME, XDG_CACHE_HOME, and OPENCHAMBER_DATA_DIR environment
        (`<dataDir>/.config/openchamber`). When `user` points at an existing
        login account, HOME/XDG are inherited from that account instead, so
        personal-user instances keep using `~/.config/openchamber` etc.

        A custom directory outside `/var/lib/openchamber` is created via
        tmpfiles.d (owned by the service user/group) while the service
        account is defined in this evaluation. When `user` names an
        externally-managed account (LDAP/SSSD, ...), the directory must
        pre-exist with correct ownership — tmpfiles cannot chown to an
        account NixOS never defines.
      '';
    };

  /**
    Standard UI bind host option for `services.openchamber`.

    # Arguments

    - `default`: bind address (defaults to `"127.0.0.1"`).
  */
  mkHostOption =
    {
      default ? "127.0.0.1",
    }:
    lib.mkOption {
      type = lib.types.str;
      inherit default;
      description = "Host for the web UI to bind to.";
    };

  /**
    Standard UI listen port option for `services.openchamber`.

    # Arguments

    - `default`: TCP port (defaults to `3000`).
  */
  mkPortOption =
    {
      default ? 3000,
    }:
    lib.mkOption {
      type = lib.types.port;
      inherit default;
      description = "Port for the web UI to listen on.";
    };

  /**
    Standard UI password-file option for `services.openchamber`.

    Upstream has NO `*_PASSWORD_FILE` mechanism (verified at the pinned
    rev: `packages/web` reads only `--ui-password` /
    `OPENCHAMBER_UI_PASSWORD` — `bin/lib/cli-args.js:61,192`,
    `bin/lib/commands-serve.js:162,289`,
    `server/index.js:1622`, `server/lib/opencode/cli-options.js:10`).
    The file is therefore staged via `LoadCredential` and its content
    exported as `OPENCHAMBER_UI_PASSWORD` by a service wrapper at start;
    it is never copied into the store.

    # Arguments

    - `default`: path or `null` (defaults to `null`, i.e. no password).
  */
  mkPasswordFileOption =
    {
      default ? null,
    }:
    lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      inherit default;
      description = "File containing the UI password (staged via LoadCredential, exported as OPENCHAMBER_UI_PASSWORD at service start — upstream's real auth mechanism).";
    };

  /**
    Standard flag allowing unauthenticated LAN binds for `services.openchamber`.

    Verified against the pinned upstream rev:
    `server/lib/security/bind-host.js:35` (`isUnsafeUnauthenticatedLanAllowed`
    checks `OPENCHAMBER_ALLOW_UNAUTHENTICATED_LAN === 'true'`), honored by
    both the CLI pre-flight (`bin/lib/cli-network.js:156`) and the server
    gate (`server/index.js:1625`). Prefer `uiPasswordFile`; enable this
    only to consciously accept the risk.

    # Arguments

    - `default`: allow unauthenticated LAN exposure (defaults to `false`).
  */
  mkAllowUnauthenticatedLanOption =
    {
      default ? false,
    }:
    lib.mkOption {
      type = lib.types.bool;
      inherit default;
      description = ''
        Allow the server to bind a network-reachable address without UI
        password authentication (sets OPENCHAMBER_ALLOW_UNAUTHENTICATED_LAN=true).

        Upstream refuses such binds by default — prefer `uiPasswordFile`.
      '';
    };

  /**
    Standard managed-chat worktree directory option for `services.openchamber`.

    Relocates managed chat worktrees (`OPENCHAMBER_CHATS_DIR`); unset means
    upstream keeps them under its config/data root
    (`<OPENCHAMBER_DATA_DIR>/chats`, i.e. `~/.config/openchamber/chats`):
    `<dataDir>/.config/openchamber/chats` for the default system user
    (where the module forces `OPENCHAMBER_DATA_DIR`),
    `~/.config/openchamber/chats` of the login user for a custom `user`.

    Verified against the pinned upstream rev: the chats directory defaults
    to `<config-root>/chats` (`server/index.js:285-287`) where the config
    root is `OPENCHAMBER_DATA_DIR` when set, else `~/.config/openchamber`
    (`server/index.js:277-280`).

    # Arguments

    - `default`: path or `null` (defaults to `null`, i.e. unset).
  */
  mkChatsDirOption =
    {
      default ? null,
    }:
    lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      inherit default;
      description = ''
        Directory for managed chat worktrees (passed as OPENCHAMBER_CHATS_DIR).

        When unset, upstream keeps them under its config/data root
        (`<OPENCHAMBER_DATA_DIR>/chats`, i.e. `~/.config/openchamber/chats`):
        `<dataDir>/.config/openchamber/chats` for the default system user
        (where the module forces `OPENCHAMBER_DATA_DIR`),
        `~/.config/openchamber/chats` of the login user for a custom `user`.
      '';
    };

  /**
    Standard LAN-bind shortcut option for `services.openchamber`.

    Mirrors upstream `openchamber serve --lan`: when no explicit `host` is
    given, the CLI binds `0.0.0.0` instead of loopback. Upstream then
    requires UI password authentication for the network-exposed bind (see
    `allowUnauthenticatedLan`).

    # Arguments

    - `default`: bind all interfaces when `host` is at its default (defaults to `false`).
  */
  mkLanOption =
    {
      default ? false,
    }:
    lib.mkOption {
      type = lib.types.bool;
      inherit default;
      description = ''
        Bind all interfaces (`0.0.0.0`) when `host` is left at its loopback
        default — the Nix equivalent of `openchamber serve --lan` (the flag
        itself is passed only in that case, mirroring upstream
        `bin/lib/cli-args.js:543`, which ignores `--lan` under an explicit
        `--host`; `--host` always carries the effective address).

        A network-exposed bind requires `uiPasswordFile` (or
        `allowUnauthenticatedLan`) — evaluation fails fast otherwise,
        mirroring upstream's refusal to serve LAN without UI auth.
      '';
    };

  /**
    Standard external OpenCode server URL option for `services.openchamber`.

    Points the server at an already-running OpenCode instance
    (`OPENCODE_HOST`, e.g. `http://hostname:4096`) instead of its managed
    one. Takes precedence over `opencodePort` when both are set (upstream
    `resolveOpenCodeEnvConfig`); combine with `skipOpencodeStart` to stop
    the server from spawning its own OpenCode process.

    # Arguments

    - `default`: URL or `null` (defaults to `null`, i.e. managed OpenCode).
  */
  mkOpencodeHostOption =
    {
      default ? null,
    }:
    lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      inherit default;
      example = "http://hostname:4096";
      description = ''
        Base URL of an external OpenCode server to use (passed as
        OPENCODE_HOST). Must use an http(s) scheme with an explicit port
        and no path/query/hash — upstream ignores (with a warning) anything
        else.
      '';
    };

  /**
    Standard managed-OpenCode bind hostname option for `services.openchamber`.

    Bind hostname for the OpenCode server this service manages
    (`OPENCHAMBER_OPENCODE_HOSTNAME`, upstream default `127.0.0.1`).
    Upstream falls back to loopback (with an error log) when given an
    invalid hostname or IP.

    # Arguments

    - `default`: bind hostname (defaults to `"127.0.0.1"`).
  */
  mkOpencodeHostnameOption =
    {
      default ? "127.0.0.1",
    }:
    lib.mkOption {
      type = lib.types.str;
      inherit default;
      description = "Bind hostname for the managed OpenCode server (passed as OPENCHAMBER_OPENCODE_HOSTNAME).";
    };

  /**
    Standard external OpenCode server port option for `services.openchamber`.

    Port of an already-running OpenCode instance to connect to
    (`OPENCODE_PORT`). Ignored when `opencodeHost` is set; combine with
    `skipOpencodeStart` to stop the server from spawning its own OpenCode
    process.

    # Arguments

    - `default`: TCP port or `null` (defaults to `null`, i.e. managed OpenCode).
  */
  mkOpencodePortOption =
    {
      default ? null,
    }:
    lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      inherit default;
      description = "Port of an external OpenCode server to connect to (passed as OPENCODE_PORT).";
    };

  /**
    Standard managed-OpenCode binary package option for `services.openchamber`.

    Supplies the `opencode` binary placed on the server wrapper's PATH
    (the server resolves its managed binary via PATH — upstream
    `server/lib/opencode/env-runtime.js` — independent of `package`).
    `opencodeVersion` in `versions.nix` is a release-line pin (the
    `@opencode-ai/sdk` pin in `packages/web`), informational basis for
    the major-skew warning; the server declares no minimum CLI version.
    Major skew surfaces as a warning, never an evaluation error, so a
    lagging nixpkgs keeps evaluating.

    # Arguments

    - `default`: opencode package (no default of its own — pass
      `extpkgs.opencode or pkgs.opencode`, mirroring `package`'s
      extpkgs-first resolution with a nixpkgs fallback: the injected
      flake scope never carries `opencode`).
  */
  mkOpencodePackageOption =
    { default }:
    lib.mkOption {
      type = lib.types.package;
      inherit default;
      defaultText = lib.literalExpression "pkgs.opencode";
      description = ''
        The opencode package placed on the server wrapper's PATH for the
        managed OpenCode subprocess (rebuilt into the runnable server, so
        overriding this swaps the managed binary).

        Should track the `opencodeVersion` release-line pin in
        `versions.nix` (from the pinned `packages/web`
        `@opencode-ai/sdk`, informational only — the server declares no
        minimum CLI version): major skew only warns — evaluation keeps
        working while nixpkgs lags — so override with a matching major
        build or wait for nixpkgs to catch up. Patch/minor drift stays
        silent.
      '';
    };

  /**
    Standard API-compression kill-switch option for `services.openchamber`.

    Sets `OPENCHAMBER_SKIP_API_COMPRESSION` (wins over the compress toggle;
    upstream compresses API responses unless skipping or running as the
    desktop runtime).

    # Arguments

    - `default`: skip API compression (defaults to `false`).
  */
  mkSkipApiCompressionOption =
    {
      default ? false,
    }:
    lib.mkOption {
      type = lib.types.bool;
      inherit default;
      description = "Skip API response compression (sets OPENCHAMBER_SKIP_API_COMPRESSION).";
    };

  /**
    Standard managed-OpenCode opt-out option for `services.openchamber`.

    Skips starting (and stopping) the managed OpenCode subprocess and uses
    an external server instead (`OPENCODE_SKIP_START=true` plus
    `OPENCHAMBER_SKIP_OPENCODE_START=true`; the server honors either
    (`server/index.js:641`, strict `=== 'true'` both) and the serve
    launcher itself forwards one into the other
    (`bin/lib/commands-serve.js:291`) — setting both is harmless, like the
    `--api-only` flag/env pairing). Combine with `opencodeHost` /
    `opencodePort`.

    # Arguments

    - `default`: skip the managed OpenCode server (defaults to `false`).
  */
  mkSkipOpencodeStartOption =
    {
      default ? false,
    }:
    lib.mkOption {
      type = lib.types.bool;
      inherit default;
      description = "Use an external OpenCode server instead of spawning a managed one (sets OPENCODE_SKIP_START and OPENCHAMBER_SKIP_OPENCODE_START).";
    };

  /**
    Standard verbose request-logging option for `services.openchamber`.

    Sets `OPENCHAMBER_VERBOSE_REQUEST_LOGS` (upstream logs every request
    when enabled).

    # Arguments

    - `default`: verbose request logs (defaults to `false`).
  */
  mkVerboseRequestLogsOption =
    {
      default ? false,
    }:
    lib.mkOption {
      type = lib.types.bool;
      inherit default;
      description = "Log every request (sets OPENCHAMBER_VERBOSE_REQUEST_LOGS).";
    };

  /**
    Freeform service settings option (RFC 0042 style).

    Any attribute set; validated against the JSON format type so it can
    be serialized verbatim with `pkgs.formats.json`.

    # Arguments

    - `jsonType`: e.g. `(pkgs.formats.json {}).type`.
    - `default`: settings (defaults to `{}`).
  */
  mkSettingsOption =
    {
      jsonType,
      default ? { },
    }:
    lib.mkOption {
      type = lib.types.submodule {
        freeformType = jsonType;
      };
      inherit default;
      description = ''
        Freeform OpenChamber settings, serialized to JSON.

        Empty by default (service behavior unchanged). When non-empty,
        the module seeds the live settings document
        (`$OPENCHAMBER_DATA_DIR/settings.json` — the only settings path
        the pinned upstream reads: `server/index.js:320`, rooted at
        `OPENCHAMBER_DATA_DIR` or `~/.config/openchamber`; upstream has no
        settings env var or `serve` flag) via `ExecStartPre` on first
        start only: an existing non-empty file is never touched, so edits
        made through the running UI (or by hand) survive every (re)start.
        Later Nix-side changes do NOT apply while the file exists — to
        re-seed, delete the file (or empty it) and restart the service.

        Never put secrets in settings: the generated file lives in the
        world-readable Nix store. Use password-file / credential options
        for secrets.
      '';
    };

  /**
    Server URL option for `programs.openchamber.gui`.

    When set, the Home Manager module installs a wrapped GUI that skips
    its bundled local server (`OPENCHAMBER_SKIP_LOCAL_SERVER=1`) and
    points at the given server (`OPENCHAMBER_SERVER_URL=<url>`).

    NOTE: both variables are undocumented upstream — honored by the
    Electron main process at the pinned rev (`v1.23.0/d073858`:
    `packages/electron/main.mjs:1436-1439` skips the local server,
    `:2984-3034` overrides the connection target from the env). They may
    change or disappear in future upstream releases.

    # Arguments

    - `default`: server URL or `null` (defaults to `null`, i.e. plain
      unwrapped install with the GUI's own local server).
  */
  mkGuiServerUrlOption =
    {
      default ? null,
    }:
    lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      inherit default;
      example = "http://127.0.0.1:3000";
      description = ''
        URL of the OpenChamber server the desktop GUI should connect to
        instead of spawning its own local server (sets
        OPENCHAMBER_SKIP_LOCAL_SERVER=1 and OPENCHAMBER_SERVER_URL=<url>
        on the wrapped `openchamber-gui` binary).

        Both variables are undocumented upstream (honored by the Electron
        main process at the pinned rev) and may change or disappear in
        future upstream releases.

        When left `null` while home-manager runs as a NixOS submodule
        with `services.openchamber.enable = true`, the GUI auto-points at
        that service (see `guiServerUrlFromService`); otherwise the plain
        unwrapped package is installed.
      '';
    };

  /**
    Build the GUI server URL for a `services.openchamber` bind.

    Mirrors the service's effective-host logic (`lan` fills a
    loopback-default `host` in as `0.0.0.0`; an explicit `host` wins),
    then maps wildcard binds (`0.0.0.0`, `::`, `[::]`) back to loopback
    (`127.0.0.1`): the service must listen on the wildcard, but a local
    GUI dials the loopback address.

    # Arguments

    - `host`: service bind host (defaults to `"127.0.0.1"`).
    - `lan`: LAN-bind shortcut (defaults to `false`).
    - `port`: service port (defaults to `3000`).

    # Example

    ```nix
    guiServerUrlFromService { host = "127.0.0.1"; lan = true; port = 3000; }
    # => "http://127.0.0.1:3000"
    ```
  */
  guiServerUrlFromService =
    {
      host ? "127.0.0.1",
      lan ? false,
      port ? 3000,
    }:
    let
      effectiveHost = if lan && host == "127.0.0.1" then "0.0.0.0" else host;
      dialHost =
        if
          builtins.elem effectiveHost [
            "0.0.0.0"
            "::"
            "[::]"
          ]
        then
          "127.0.0.1"
        else
          effectiveHost;
      isBareIpv6 =
        lib.hasInfix ":" dialHost && !(lib.hasPrefix "[" dialHost && lib.hasSuffix "]" dialHost);
      urlHost = if isBareIpv6 then "[${dialHost}]" else dialHost;
    in
    "http://${urlHost}:${toString port}";
})
