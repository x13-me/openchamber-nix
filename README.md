# OpenChamber on Nix

Nix flake packaging [OpenChamber](https://github.com/openchamber/openchamber)
(Bun workspaces monorepo: Express server + React 19 web UI + Electron 41 GUI)
with three packages, following the [helium-nix](https://github.com/x13-me/helium-nix) pattern.

## Flake outputs

```
packages
├── openchamber-server   # node wrapper around packages/web bin/cli (default)
├── openchamber-web      # static web UI assets (packages/web/dist)
├── openchamber-gui      # prebuilt Electron AppImage via wrapType2
└── openchamber-gui-appimage  # alias of openchamber-gui
apps: openchamber-server, openchamber-gui
nixosModules.openchamber  # services.openchamber
overlays.default
devShells (bun + nodejs_22)
```

## Quick Start

As a flake input:

```nix
{
  inputs.openchamber-nix.url = "github:x13-me/openchamber-nix";
}
```

Ad-hoc run / install:

```bash
nix run github:x13-me/openchamber-nix -- serve --port 3000
nix profile install github:x13-me/openchamber-nix#openchamber-gui
```

Home Manager:

```nix
{ inputs, ... }: {
  home.packages = [ inputs.openchamber-nix.packages.${pkgs.system}.openchamber-gui ];
}
```

NixOS module:

```nix
{ inputs, ... }: {
  imports = [ inputs.openchamber-nix.nixosModules.openchamber ];
  nixpkgs.overlays = [ inputs.openchamber-nix.overlays.default ];
  services.openchamber = {
    enable = true;
    port = 3000;
    host = "127.0.0.1";
    # uiPasswordFile = "/run/secrets/openchamber-password";
  };
}
```

## Features

- **Server** (`openchamber-server`): source-built `@openchamber/web`
  (`bun install --frozen-lockfile` + `packages/ui` build + `vite build`),
  wrapped with `nodejs_22` and `opencode`, `git`, `openssh`, `bash` on
  `PATH`, plus `SSL_CERT_FILE` pointed at the Nix `cacert` bundle.
  Default port 3000, `OPENCHAMBER_*` env supported.
- **Web UI** (`openchamber-web`): `dist/` assets only, no runtime deps —
  serve with any static server.
- **GUI** (`openchamber-gui`): upstream Linux AppImage repackaged with
  `appimageTools.wrapType2`, desktop entry `Exec` fixed, icons installed.
- **No self-update**: electron-updater is meaningless for immutable store
  paths — updates arrive via `versions.nix` + this flake only.

## Building Locally

```bash
nix build .#openchamber-server   # needs network in builder (bun registry)
nix build .#openchamber-web
nix build .#openchamber-gui
```

If your builder denies network in the sandbox:

```bash
nix build .#openchamber-server --option sandbox false
```

## Automated Maintenance

- `versions.nix` is the single machine-updated file
  (`version`, `rev`, `srcHash`, per-system AppImage hashes).
- `.github/update-openchamber.sh` mirrors `update-helium.sh`: `--only-check`
  gates on the latest stable release (`gh release view`, equivalent to
  `releases/latest`, prereleases excluded), otherwise validates the
  version format, dereferences annotated tags to the commit SHA,
  prefetches the source NAR hash plus both AppImage hashes, rewrites
  `versions.nix`, and runs `nix flake update`.
- `update-openchamber.yml` runs hourly (`32 * * * *`): `--only-check`
  gates, then a single `prepare-update` job runs the updater once and
  shares `versions.nix` + `flake.lock` with the 3 packages × 2 systems
  test-build matrix (native runners, `nix build` + `nix flake check`
  only) via artifact, then commits and tags `v<version>`.
- `build-openchamber.yml` (`workflow_dispatch`) builds the same matrix on demand.
- Binary cache: [openchamber](https://app.cachix.org/cache/openchamber) —
  set the `CACHIX_AUTH_TOKEN` secret. Publishing to FlakeHub additionally
  needs `FLAKEHUB_TOKEN`.
