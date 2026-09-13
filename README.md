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
nixosModules.default (+ legacy alias .openchamber)  # services.openchamber
homeManagerModules.default (+ alias homeModules.default)  # programs.openchamber-gui + programs.openchamber-server
overlays.default
devShells (bun + nodejs_22 + git + just + formatter tools)
checks.formatting       # treefmt --ci
formatter               # treefmt: nixfmt + deadnix + statix + keep-sorted
legacyPackages          # raw package scope (incl. internal builtSource)
hydraJobs               # per-package × per-system jobs
lib                     # makeExtensible helpers (archOf, mk*Option)
```

## Layout

Small-flake layout, no flake-parts/flake-utils/haumea:

```
flake.nix                  # thin root: inputs + `outputs = inputs: import ./nix inputs`
nix/
├── default.nix            # all outputs; forAllSystems via lib.genAttrs
├── overlay.nix            # system-independent _: prev: + prev.callPackage only
└── formatter.nix          # treefmt.withConfig (nixpkgs only, no extra inputs)
packages/
├── default.nix            # makeScope scope (server/web share builtSource)
├── built-source/package.nix       # internal: bun install + ui/web build
├── openchamber-server/package.nix # callPackage-compatible, no outer pkgs capture
├── openchamber-web/package.nix
└── openchamber-gui/package.nix
modules/
├── nixos/default.nix      # _class="nixos", services.openchamber
├── home-manager/default.nix  # _class="homeManager", programs.openchamber-gui
└── generic/settings.nix   # shared freeform settings option (RFC42 JSON)
lib/default.nix            # makeExtensible helpers, nixdoc comments
versions.nix               # single machine-updated file (updater only)
```

## Why no flake-parts / flake-utils

Following [isabelroses' "I'm not mad, I'm disappointed"](https://isabelroses.com/blog/im-not-mad-im-disappointed)
minimalist stance for small flakes:

- **Single `nixpkgs` input.** No `flake-parts`, `flake-utils`, `nix-systems`,
  or treefmt/pre-commit inputs to lock. `flake.lock` pins exactly one input.
- **`forAllSystems` is just `lib.genAttrs`** over an explicit system list
  (`systems in lib/default.nix` single source of truth; Linux-only because the GUI is a
  Linux AppImage). That one-liner is all flake-utils ever gave us here.
- **System-independent overlay** (`_: prev:` + `prev.callPackage` only, never
  `self.packages.${system}`), so it composes freely with other overlays.
- **Path-form modules** (`nixosModules.default = ./modules/nixos/default.nix`,
  no needless `import`), `_class` set, `nixpkgs.hostPlatform`-friendly.
- **Formatter without extra inputs**: `treefmt.withConfig` from nixpkgs
  (nixfmt + deadnix + statix + keep-sorted), exposed as `formatter` output
  and enforced by `checks.formatting` (`nix flake check` runs it).
- **No pre-commit hooks input**: `.editorconfig` covers editor consistency
  (matching isabelroses/dotfiles); CI (`check.yml`: `nix fmt -- --ci` +
  `nix flake check --no-build --all-systems`) is the enforcement point.
  Adding pre-commit-hooks.nix would mean a second lock input for what CI
  already checks.

If this flake ever grows NixOS VMs, darwin support, or per-system services,
revisit flake-parts then — not before.

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
  imports = [ inputs.openchamber-nix.homeManagerModules.default ];
  nixpkgs.overlays = [ inputs.openchamber-nix.overlays.default ];
  programs.openchamber-gui.enable = true;
  programs.openchamber-server.enable = true; # ad-hoc `openchamber serve`
}
```

NixOS module:

```nix
{ inputs, ... }: {
  imports = [ inputs.openchamber-nix.nixosModules.default ];
  nixpkgs.overlays = [ inputs.openchamber-nix.overlays.default ];
  services.openchamber = {
    enable = true;
    port = 3000;
    host = "127.0.0.1";
    # uiPasswordFile = "/run/secrets/openchamber-password";
    # settings = { };  # freeform attrs -> /etc/openchamber/settings.json
  };
}
```

Without the overlay, inject the flake's package set instead:

```nix
{ inputs, ... }: {
  _module.args.extpkgs = inputs.openchamber-nix.legacyPackages.${pkgs.stdenv.hostPlatform.system};
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

### Why builds need network (why can't you just build?)

The server/web packages compile upstream's Bun workspace from source
(`packages/built-source/package.nix`): `bun install --frozen-lockfile`
downloads dependencies from the bun/npm registry at *build* time, and
`vite build` may fetch remote fonts/assets. Nix derivations are pure by
default — the sandbox blocks network — so a sandboxed build fails in the
fetch/`bun install` phase with network errors, **not** because of a code
bug. This is inherent to source builds without a vendored lockfile hash
(`bun.lock` alone doesn't give Nix the content hashes it needs for
fixed-output fetching).

Your options, in order of preference:

1. Build on a machine whose builder allows network (GitHub-hosted
   runners work — that is why CI uses native `ubuntu-24.04` /
   `ubuntu-24.04-arm` runners instead of sandbox-relaxed builds).
2. Locally, relax the sandbox for that invocation only:
   `nix build .#openchamber-web --option sandbox false`.
3. The GUI package (`openchamber-gui`) never needs this: it repackages
   the upstream AppImage via fixed-output `fetchurl`, which is pure.

Sandboxing is deliberately **not** disabled in code — relaxing it is a
local/CI policy decision, documented here instead.

## Development

```bash
nix fmt -- --ci              # check formatting (nixfmt + deadnix + statix + keep-sorted)
nix flake check --no-build --all-systems
nix build .#checks.x86_64-linux.formatting  # run the formatting check as a derivation
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
- `build-openchamber.yml` (`workflow_dispatch` + `pull_request`) builds the same matrix on demand.
- `check.yml` (push to main + PRs, both Linux systems): `nix flake check
  --no-build --all-systems` plus `nix fmt -- --ci`.
- `flakehub-publish.yml` triggers on `v*` tags (builds server, then pushes via `fh`).
- Binary cache: [openchamber](https://app.cachix.org/cache/openchamber) —
  set the `CACHIX_AUTH_TOKEN` secret. Publishing to FlakeHub additionally
  needs `FLAKEHUB_TOKEN`.
