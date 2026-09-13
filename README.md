# OpenChamber on Nix

Nix flake packaging [OpenChamber](https://github.com/openchamber/openchamber)
(Bun workspaces monorepo: Express server + React 19 web UI + Electron 41 GUI)
with two packages, following the [helium-nix](https://github.com/x13-me/helium-nix) pattern.

## Flake outputs

```
packages
├── openchamber-server   # node wrapper around packages/web bin/cli (default, serves builtin web UI)
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
├── default.nix            # makeScope scope (server uses builtSource)
├── built-source/package.nix       # internal: bun install + ui/web build
├── openchamber-server/package.nix # callPackage-compatible, no outer pkgs capture
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
    # Runs as a dedicated `openchamber` system user by default. To give the
    # server direct access to your HOME, ~/.ssh, git config, and workspace
    # files, run it as your login user instead (`user` and `group` must be
    # customized together — setting only one is an evaluation error):
    # user = "youruser";
    # group = "users";
    # uiPasswordFile = "/run/secrets/openchamber-password";
    # enableWebUI = false;  # API-only mode: REST API without browser UI assets
    # lan = true;  # bind 0.0.0.0 (needs uiPasswordFile, or allowUnauthenticatedLan = true)
    # opencodeHost = "http://hostname:4096";  # external OpenCode server (with skipOpencodeStart = true)
    # opencodePort = 4096;  # external OpenCode port (ignored when opencodeHost is set)
    # opencodeHostname = "127.0.0.1";  # bind hostname for the managed OpenCode server
    # chatsDir = "/var/lib/openchamber-chats";  # relocate managed chat worktrees
    # verboseRequestLogs = true;  # log every request
    # skipApiCompression = true;  # skip API response compression
    # settings = { };  # freeform attrs -> /etc/openchamber/settings.json
  };
  # When enabled, the service account gets the CLI on PATH
  # (`users.users.<user>.packages`), so it can run `openchamber status` /
  # pairing / `tunnel` management commands. When `user` is managed outside
  # the same evaluation (e.g. LDAP/SSSD), set `installCliForUser = false`
  # (and install the CLI on PATH for that account separately) — otherwise
  # the module would implicitly create a local account shadowing it.
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
- **Web UI**: embedded `dist/` assets inside `openchamber-server` — the
  builtin Express server is required; there is no standalone static
  package (nginx-alone would serve a dead shell).
- **GUI** (`openchamber-gui`): upstream Linux AppImage repackaged with
  `appimageTools.wrapType2`, desktop entry `Exec` fixed, icons installed.
- **No self-update**: electron-updater is meaningless for immutable store
  paths — updates arrive via `versions.nix` + this flake only.

## Building Locally

```bash
nix build .#openchamber-server   # needs network in builder (bun registry)
nix build .#openchamber-gui
```

If your builder denies network in the sandbox:

```bash
nix build .#openchamber-server --option sandbox false
```

### Why builds need network (why can't you just build?)

The server package compiles upstream's Bun workspace from source
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
    `nix build .#openchamber-server --option sandbox false`.
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
- `.github/update-openchamber.sh` mirrors `update-helium.sh` (`--ci` /
  `--only-check` flags, `should_update` / `version` / `commit_message`
  outputs, `GH_TOKEN` auth, retry-on-404, `nix store prefetch-file` +
  conditional `nix flake update`): polls `releases/latest` (stable only,
  prereleases excluded), validates the version format, dereferences
  annotated tags to the commit SHA, prefetches the source NAR hash plus
  both AppImage hashes, rewrites `versions.nix`, and runs
  `nix flake update` (only under `--ci` on the update path).
- `update-openchamber-main.yml` (`32 * * * *`, hourly) is the single updater:
  `main` follows the upstream latest release — `--only-check` gates, then
  update → auto-commit + tag `v<version>` → 2 packages × 2 systems
  test-build matrix.
- `build-openchamber.yml` (`workflow_dispatch`) builds the same matrix on demand.
- `flakehub-publish-tagged.yml` (`v?[0-9]+.[0-9]+.[0-9]+*` tags / dispatch)
  is the single publish path: pushes of `v*` tags (created by the updater
  on main, plus manual tags/dispatch) publish that version to FlakeHub as
  `x13-me/openchamber-nix`. Plain main commits do not publish. No `rolling`
  channel — every publish is version-tagged.
- Deliberate divergence from helium-nix dual-branch spec: helium tracks
  stable on main plus prereleases on a `rolling` branch (second updater +
  push-to-both publish); this repo collapses to a single `main` branch
  tracking upstream latest only — no `rolling` branch, no rolling updater
  workflow, no `rolling: true` publish, no main-push publish; only tag
  pushes publish.
  As before, `check.yml` (push to main + PRs,
  both Linux systems: `nix flake check --no-build --all-systems` plus
  `nix fmt -- --ci`) is kept alongside the replicated workflows, as are
  the flake's `checks` / `devShells` / formatter / modules.
- Binary cache: [openchamber](https://app.cachix.org/cache/openchamber) —
  set the `CACHIX_AUTH_TOKEN` secret. Publishing to FlakeHub uses OIDC
  (`id-token: write`), no extra secret needed.
