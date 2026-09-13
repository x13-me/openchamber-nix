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

    The file is staged via `LoadCredential` so the service never needs
    direct read access to the raw host path; it is never copied into the store.

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
      description = "File containing the UI password (passed as OPENCHAMBER_UI_PASSWORD_FILE).";
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
        the module writes `/etc/openchamber/settings.json` and points
        the service at it — confirm the exact flag/env contract against
        `openchamber serve --help` for your pinned version.

        Never put secrets in settings: the generated file lives in the
        world-readable Nix store (the `/etc` copy is mode `0440`, but the
        store copy stays readable). Use password-file / credential options
        for secrets.
      '';
    };
})
