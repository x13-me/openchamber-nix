# CI Replication Spec — Helium-Nix (GitHub Actions)

> **Deprecation note:** This spec describes the original Helium dual-branch (`main`/`rolling`) design.
> This repo deliberately diverged in commit `326872d` to singular `main` tracking upstream latest.
> There is no `rolling` branch/workflow; `flakehub-publish-rolling.yml` fires on `main` only, and `rolling: true` is the FlakeHub channel.

> Source repo: `helium-nix` (`/home/user/helium-nix`).
> This document specifies the CI exactly as implemented so it can be replicated
> identically in other repos using the same mechanisms and structure.

## 1. Goal

Replicate the `helium-nix` CI **identically** in another repo by copying the same
file layout, workflow triggers/permissions/steps, helper script contract, Nix
flake contract, caching strategy, secrets, and branch/tag protections — changing
only the documented customization points (names, branches, cron, upstream
release source, assets, packages).

Placeholders used in this doc:

| Placeholder | Meaning | Example in this repo |
|---|---|---|
| `<OWNER>` | GitHub owner/org | `x` (FlakeHub `x/helium-nix`) |
| `<REPO>` | GitHub repo name | `helium-nix` |
| `<CACHE-NAME>` | Cachix binary cache name | `x13` |
| `<FLAKEHUB-NAME>` | FlakeHub `owner/repo` handle | `x/helium-nix` |
| `<UPSTREAM-OWNER>` | Upstream release owner | `imputnet` |
| `<UPSTREAM-REPO>` | Upstream release repo | `helium-linux` |
| `<MAIN-BRANCH>` | Primary rolling-release branch | `main` |
| `<ROLLING-BRANCH>` | Secondary tracking branch | `rolling` |

Replace every `<...>` before committing. Do not leave placeholders in a live repo.

## 2. Scope / Non-Goals

### In scope

- GitHub Actions only — 5 workflows in `.github/workflows/`.
- Helper script `.github/update-helium.sh`.
- Nix flake contract: `flake.nix` + `versions.nix` (sole version source) + `flake.lock`.
- FlakeHub publishing (rolling + tagged).
- Hourly upstream-release polling + auto-commit + conditional test-build matrix.
- Cachix + FlakeHub cache + Determinate Nix installer wiring.
- Secrets/permissions, branch/tag protection recommendations, verification.

### Non-goals (explicitly NOT present — do not add when replicating)

- No GitLab CI / Jenkins / CircleCI.
- No `pre-commit`, no Dependabot config.
- No `.github/actions/` (no reusable workflows, no composite actions).
- No `nix flake check`, no `devShells`.
- No lint/format tooling: no `nixfmt`, `statix`, `deadnix`, `eslint`.
- DRY is achieved **only** via the shared shell script + duplicated 4-entry
  matrix `include:` blocks + `needs:`/`outputs:` gating. Do not introduce
  reusable workflows unless you are intentionally diverging.

## 3. Architecture Overview (diagram as text)

```text
                    +----------------------------+
                    | upstream releases          |
                    | github.com/<UPSTREAM-OWNER>/|
                    |   <UPSTREAM-REPO>/releases |
                    |   /latest  (tag e.g. v1.2.3)|
                    +-------------+--------------+
                                  | curl API (hourly cron)
                                  v
              +---------------------------------------+
              | update-helium-main.yml  (branch: main)|
              | update-helium-rolling.yml (branch: rolling)|
              |  job1: update-helium-browser          |
              |   check (.github/update-helium.sh     |
              |     --ci --only-check) -> should_update?|
              |   if true: install nix, update script |
              |     --ci, git-auto-commit (*), tag    |
              |     (main only: git tag vVERSION)     |
              +-----+-----------------+---------------+
                    | needs: success==true
                    v
              +---------------------------------------+
               | job2: test-build (4-matrix include)   |
               |  nix build ".#helium-appimage" /      |
               |            ".#helium-tarball"         |
               |            x86_64/aarch64-linux       |
              +---------------------------------------+

  build-helium.yml (workflow_dispatch only):
    same 4-matrix, nix build ".#${{ matrix.package }}"

  flakehub-publish-rolling.yml (push to main/rolling):
    flakehub-push rolling:true visibility:public

  flakehub-publish-tagged.yml (push tags v?[0-9]+... / dispatch):
    flakehub-push tag:<tag> visibility:public

  Shared state:
    versions.nix  <-- ONLY file mutated by CI (sole version source)
    flake.lock    <-- updated only when script runs with --ci
    flake.nix     <-- static (121 lines), reads versions.nix

  Caches/substituters:
    DeterminateSystems/flakehub-cache-action + cachix/cachix-action (cache <CACHE-NAME>)
```

Flow summary:

1. Hourly cron (or push/dispatch) runs the update workflow for its branch.
2. `--only-check` decides `should_update` without mutating anything.
3. If `true`, the full update runs: prefetch 4 assets, rewrite `versions.nix`,
   optionally `nix flake update`, auto-commit, optionally tag.
4. `test-build` rebuilds all 4 package/arch combos on the updated branch ref.
5. Pushes to `main`/`rolling` trigger FlakeHub rolling publish; tag pushes
   trigger FlakeHub tagged publish. `build-helium.yml` is manual verification.

## 4. Prerequisites

| Requirement | Detail |
|---|---|
| GitHub repo | A GitHub repo with branches `<MAIN-BRANCH>` / `<ROLLING-BRANCH>` (here: `main`, `rolling`; a remote `origin/tarball` branch also exists for packaging experiments — `git branch -a` shows `remotes/origin/tarball`). |
| FlakeHub account | FlakeHub project handle `<FLAKEHUB-NAME>` (here: `x/helium-nix`). Rolling publishes map branches; tagged publishes map `v*` tags. |
| Cachix cache | Cachix cache `<CACHE-NAME>` (here: `x13`). Required secret below. |
| Secrets | `CACHIX_AUTH_TOKEN` (Cachix auth token, used by `cachix/cachix-action`). `GH_TOKEN` is **not** a stored secret — the update check uses `env: GH_TOKEN: ${{ github.token }}` (the built-in `GITHUB_TOKEN`). |
| Permissions | Workflows need `contents:read` minimum; update job needs `contents:write`; FlakeHub publish and Determinate-backed builds need `id-token:write`. See §10. |
| Runner labels | `ubuntu-24.04` (x86_64), `ubuntu-24.04-arm` (aarch64), `ubuntu-latest` (publish). aarch64 Linux builds run on `ubuntu-24.04-arm`. |
| Tooling on runner | `curl`, `jq`, `nix`, `git` (update script requirement). Provided by checkout + Nix installer steps; `jq` is preinstalled on `ubuntu-*` images. |
| Nix input | Single `nixpkgs` input following `nixos-unstable`, locked in `flake.lock`. No other flake inputs. |
| Bot self-push | The repo must allow the `github-actions[bot]` to push to protected branches (see §11), otherwise the auto-commit/tag steps fail. |

## 5. Canonical File Tree

Copy this layout exactly (5 workflows + 1 helper + 3 Nix files):

```text
<REPO>/
  .github/
    workflows/
      build-helium.yml
      flakehub-publish-rolling.yml
      flakehub-publish-tagged.yml
      update-helium-main.yml
      update-helium-rolling.yml
    update-helium.sh          # POSIX sh, executable
  flake.nix                   # 121 lines; packages only, reads versions.nix
  versions.nix                # SOLE version source; mutated by CI
  flake.lock                  # locked; updated only via `nix flake update` with --ci
```

What is **absent** (verify absence when replicating — confirmed here via glob:
no matches for `.github/actions/**`, `.gitlab-ci.yml`, `Jenkinsfile`,
`.pre-commit-config.yaml`, `.github/dependabot.yml`):

```text
# NONE of these exist — do not create them:
.github/actions/
.gitlab-ci.yml
Jenkinsfile
.pre-commit-config.yaml
.github/dependabot.yml
```

`flake.nix` exposes no `checks` and no `devShells` — packages only.

## 6. Workflow Specs

Conventions: `runs-on` is always from the matrix (`matrix.runner`) for build
matrices, else `ubuntu-24.04` (update jobs) or `ubuntu-latest` (FlakeHub publish).
Action pins are part of the spec — preserve them, including the intentional
`v5` vs `v6` / `main` vs `v3` drift noted in §12.

### 6.1 `build-helium.yml` — Manual build matrix

- **Purpose:** On-demand verification of both packages × both architectures.
  No publish, no commit, no tag.
- **Name:** `Build Helium Browser`.
- **Triggers (copy verbatim):**

```yaml
on:
  workflow_dispatch:
```

- **Permissions (job-level):**

```yaml
permissions:
  id-token: "write"
  contents: read
```

- **Jobs/steps:**

| Job | runs-on | Steps (in order, with versions) |
|---|---|---|
| `build` (`build-helium.yml` L7; `name: Build ${{ matrix.package }} (${{ matrix.system }})`, L8) (4-matrix `include:`, see key YAML) | `${{ matrix.runner }}` | 1. `actions/checkout@v5` 2. `DeterminateSystems/determinate-nix-action@main` 3. `DeterminateSystems/flakehub-cache-action@main` 4. `cachix/cachix-action@v17` with `name: <CACHE-NAME>` (`x13` here), `authToken: '${{ secrets.CACHIX_AUTH_TOKEN }}'` 5. `run: nix build ".#${{ matrix.package }}"` |

- **Key YAML to copy (matrix + steps):**

```yaml
jobs:
  build: # job ID is `build` (build-helium.yml L7), not `build-helium`
    name: Build ${{ matrix.package }} (${{ matrix.system }}) # L8
    strategy:
      matrix:
        include:
          - system: x86_64-linux
            runner: ubuntu-24.04
            package: helium-appimage
          - system: x86_64-linux
            runner: ubuntu-24.04
            package: helium-tarball
          - system: aarch64-linux
            runner: ubuntu-24.04-arm
            package: helium-appimage
          - system: aarch64-linux
            runner: ubuntu-24.04-arm
            package: helium-tarball
    runs-on: ${{ matrix.runner }}
    permissions:
      id-token: "write"
      contents: read
    steps:
      - uses: actions/checkout@v5
      - uses: DeterminateSystems/determinate-nix-action@main
      - uses: DeterminateSystems/flakehub-cache-action@main
      - uses: cachix/cachix-action@v17
        with:
          name: <CACHE-NAME>
          authToken: '${{ secrets.CACHIX_AUTH_TOKEN }}'
      - run: nix build ".#${{ matrix.package }}"
```

- **Customization points:**

| What to rename | Where | Notes |
|---|---|---|
| `<CACHE-NAME>` | `cachix-action` `name:` | Your Cachix cache name. |
| Package names | `matrix.package` + `nix build` arg | Must match `flake.nix` `packages.*` outputs. |
| Runner labels | `matrix.runner` | Change only if your architectures/hosts differ. Keep x86_64 ↔ `ubuntu-24.04`, aarch64 ↔ `ubuntu-24.04-arm` mapping unless you have a reason. |
| Checkout pin | `actions/checkout@v5` | Kept at `v5` here while other workflows use `v6` (see pitfalls). Align deliberately or preserve drift. |

### 6.2 `flakehub-publish-rolling.yml` — Publish every push to FlakeHub

- **Purpose:** Publish the flake to FlakeHub as a rolling release on every push
  to the tracked branches.
- **Name:** `Publish every Git push to FlakeHub`.
- **Triggers (copy verbatim, rename branches only):**

```yaml
on:
  push:
    branches:
      - "main"
      - "rolling"
```

- **Permissions (job-level):**

```yaml
permissions:
  id-token: write
  contents: read
```

- **Jobs/steps:**

| Job | runs-on | Steps (in order, with versions) |
|---|---|---|
| Single job | `ubuntu-latest` | 1. `actions/checkout@v6` with `persist-credentials: false` 2. `DeterminateSystems/determinate-nix-action@v3` 3. `DeterminateSystems/flakehub-push@main` with `name: <FLAKEHUB-NAME>`, `rolling: true`, `visibility: public`, `include-output-paths: true` |

- **Key YAML to copy:**

```yaml
jobs:
  flakehub-publish: # flakehub-publish-rolling.yml L8
    runs-on: "ubuntu-latest"
    permissions:
      id-token: "write"
      contents: "read"
    steps:
      - uses: "actions/checkout@v6"
        with:
          persist-credentials: false
      - uses: "DeterminateSystems/determinate-nix-action@v3"
      - uses: "DeterminateSystems/flakehub-push@main"
        with:
          name: <FLAKEHUB-NAME>   # e.g. x/helium-nix
          rolling: true
          visibility: "public"
          include-output-paths: true
```

- **Customization points:**

| What to rename | Where | Notes |
|---|---|---|
| Branches | `on.push.branches` | List every branch that should publish rolling. |
| `<FLAKEHUB-NAME>` | `flakehub-push` `name:` | Your FlakeHub `owner/repo` handle. |
| `visibility` | `flakehub-push` | `public` here; use `private` only if your FlakeHub plan supports it. |
| Installer pin | `determinate-nix-action@v3` | Rolling-update workflow intentionally uses a different installer (see §6.4); publish workflows stay on Determinate `v3`. |

### 6.3 `flakehub-publish-tagged.yml` — Publish tags to FlakeHub

- **Purpose:** Publish versioned FlakeHub releases from Git tags (plus manual
  re-publish via dispatch).
- **Name:** `Publish tags to FlakeHub`.
- **Triggers (copy verbatim):**

```yaml
on:
  push:
    tags:
      - "v?[0-9]+.[0-9]+.[0-9]+*"
  workflow_dispatch:
    inputs:
      tag:
        description: 'Tag to publish'
        required: true
        type: string
```

- **Permissions:** Same as rolling publish (`id-token: write`, `contents: read`).
- **Jobs/steps:**

| Job | runs-on | Steps (in order, with versions) |
|---|---|---|
| `flakehub-publish` (`flakehub-publish-tagged.yml` L13; `runs-on: ubuntu-latest`, permissions `id-token: write`, `contents: read`) | `ubuntu-latest` | 1. `actions/checkout@v6` with `persist-credentials: false`, `ref: "${{ (inputs.tag != null) && format('refs/tags/{0}', inputs.tag) || '' }}"` (exact, L22 — null guard + `refs/tags/` prefix; empty string on `push.tags` resolves to the default checkout ref, i.e. the pushed tag) 2. `DeterminateSystems/determinate-nix-action@v3` 3. `DeterminateSystems/flakehub-push@main` with `visibility: public`, `name: <FLAKEHUB-NAME>`, `tag: "${{ inputs.tag }}"` (empty on `push.tags`; `flakehub-push` infers the tag from the checked-out ref), `include-output-paths: true` |

- **Key YAML to copy (full scaffold):**

```yaml
jobs:
  flakehub-publish: # flakehub-publish-tagged.yml L13
    runs-on: "ubuntu-latest"
    permissions:
      id-token: "write"
      contents: "read"
    steps:
      - uses: "actions/checkout@v6"
        with:
          persist-credentials: false
          ref: "${{ (inputs.tag != null) && format('refs/tags/{0}', inputs.tag) || '' }}"
      - uses: "DeterminateSystems/determinate-nix-action@v3"
      - uses: "DeterminateSystems/flakehub-push@main"
        with:
          visibility: "public"
          name: <FLAKEHUB-NAME>
          tag: "${{ inputs.tag }}" # empty on push.tags; flakehub-push infers ref
          include-output-paths: true
```

> Note: on `push.tags` events `inputs.tag` is empty, so checkout `ref` evaluates
> to `''` and checkout defaults to the pushed tag ref. On `workflow_dispatch`
> the caller supplies `tag`, which the expression formats as `refs/tags/<tag>`
> for checkout while `flakehub-push` receives the raw `tag` value (on push it
> infers the tag from the checked-out ref). Preserve this dual-trigger shape
> when copying.

- **Customization points:**

| What to rename | Where | Notes |
|---|---|---|
| Tag glob | `on.push.tags` | Keep `v?[0-9]+.[0-9]+.[0-9]+*` unless your versioning differs. Must match the tag format your update workflow pushes (here `vVERSION`). |
| `<FLAKEHUB-NAME>` | `flakehub-push` `name:` | Same handle as rolling publish. |
| Checkout `ref` | `ref: "${{ (inputs.tag != null) && format('refs/tags/{0}', inputs.tag) || '' }}"` | Keep the exact null-guard + `refs/tags/` expression verbatim; do not hardcode a branch or simplify to `ref: ${{ inputs.tag }}`. |

### 6.4 `update-helium-main.yml` — Poll upstream, update, tag, test-build

- **Purpose:** Hourly (plus push/dispatch) upstream poll for the `main` branch:
  check → conditionally install Nix → update `versions.nix` → auto-commit →
  push Git tag `vVERSION` → 4-matrix test-build.
- **Name:** `Update Helium Browser [main]`.
- **Triggers (copy verbatim, rename branch/cron only):**

```yaml
on:
  workflow_dispatch:
  push:
    branches:
      - main
  schedule:
    - cron: "32 * * * *"
```

- **Job 1 — `update-helium-browser` (`name: Update Helium Browser`, `update-helium-main.yml` L13):**

```yaml
runs-on: ubuntu-24.04
permissions:
  contents: write
  id-token: write
```

| Step | Uses / run | Condition / env |
|---|---|---|
| Checkout | `actions/checkout@v6` with `ref: main` | always |
| Check (`id: check`, L24) | `run: .github/update-helium.sh --ci --only-check`, `env: GH_TOKEN: ${{ github.token }}` | always; exports `should_update`, `version`, `commit_message` to `GITHUB_OUTPUT` |
| Install Nix | `DeterminateSystems/determinate-nix-action@main` | `if: steps.check.outputs.should_update == 'true'` |
| FlakeHub cache | `DeterminateSystems/flakehub-cache-action@main` | same `if` |
| Cachix | `cachix/cachix-action@v17` (`name: <CACHE-NAME>`, `authToken: secrets.CACHIX_AUTH_TOKEN`) | same `if` |
| Update (`id: update`, L48) | `run: .github/update-helium.sh --ci` | same `if` |
| Commit (`id: commit`, L56) | `stefanzweifel/git-auto-commit-action@v7` with `commit_message: ${{ steps.update.outputs.commit_message }}`, `file_pattern: "*"` | same `if` |
| Tag | `run: git tag "v${{ steps.update.outputs.version }}" && git push origin "v${{ steps.update.outputs.version }}"` | same `if`; **main only** |
| Outputs | `success` (L68: `success: ${{ steps.update.outputs.should_update }}`) | consumed by job 2 |

- **Job 2 — `test-build` (`name: Test build ${{ matrix.package }} (${{ matrix.system }})`, `update-helium-main.yml` L73):**

```yaml
needs: update-helium-browser
if: needs.update-helium-browser.outputs.success == 'true'
continue-on-error: false
strategy.matrix.include: # SAME 4 entries as §6.1
runs-on: ${{ matrix.runner }}
permissions: # present on main job2 (update-helium-main.yml L91-93)
  contents: write
  id-token: write
steps:
  - uses: actions/checkout@v6
    with:
      ref: main
  - uses: DeterminateSystems/determinate-nix-action@main
  - uses: DeterminateSystems/flakehub-cache-action@main
  - run: nix build ".#${{ matrix.package }}"
```

> The `push: branches: [main]` trigger means the auto-commit itself re-triggers
> the workflow; the `--only-check` gate then reports `should_update=false` and
> both the update steps and `test-build` are skipped — this is the intended
> idempotency, not a loop bug.

- **Customization points:**

| What to rename | Where | Notes |
|---|---|---|
| Branch | `on.push.branches`, checkout `ref:` | Your primary branch. |
| Cron | `schedule.cron` | `32 * * * *` here; keep staggered vs secondary branch (see §6.5). |
| `<CACHE-NAME>` | `cachix-action` | Your cache. |
| Upstream + assets | **Do not edit YAML** — edit `.github/update-helium.sh` (URL, grep/sed, asset list). | See §7. |
| Tag step | `git tag v...` | Keep on primary branch; omit on secondary (see §6.5). |
| Step IDs | `steps.check` / `steps.update` (`id: check` L24, `id: update` L48, `id: commit` L56) | Copy the literal IDs — `if:` gates and output references (`steps.check.outputs.should_update`, `steps.update.outputs.commit_message`, `steps.update.outputs.version`) must match. |

### 6.5 `update-helium-rolling.yml` — Identical except noted deltas

- **Purpose:** Same poll/update/test-build loop for the `rolling` branch.
- **Name:** `Update Helium Browser [rolling]`.
- **Job names:** job 1 `name: Update Helium Browser` (`update-helium-rolling.yml` L13); job 2 `name: Test build ${{ matrix.package }} (${{ matrix.system }})` (L68) — same templates as main (L13/L73).
- **Triggers:**

```yaml
on:
  workflow_dispatch:
  push:
    branches:
      - rolling
  schedule:
    - cron: "33 * * * *"   # staggered +1 min vs main to avoid races
```

- **Deltas vs `update-helium-main.yml` (all other steps identical):**

| Area | `main` workflow | `rolling` workflow |
|---|---|---|
| Job 1 permissions | `contents: write` + `id-token: write` | `contents: write` **only** (no `id-token`) |
| Job 1 Nix installer | `DeterminateSystems/determinate-nix-action@main` | `cachix/install-nix-action@v31` with `nix_path: nixpkgs=channel:nixpkgs-unstable` |
| Job 1 FlakeHub cache | `DeterminateSystems/flakehub-cache-action@main` (L37) | `DeterminateSystems/flakehub-cache-action@main` (L38) — present in **both** |
| Job 2 installer | `determinate-nix-action@main` + `flakehub-cache-action@main` | `cachix/install-nix-action@v31` (same `nix_path`) + `flakehub-cache-action@main` (L97-98) — only the installer diverges, cache is present in both |
| Job 2 permissions | `contents: write` + `id-token: write` (`update-helium-main.yml` L91-93) | no permissions block (inherits defaults) — only rolling job 2 has none |
| Tag step | **present** (`git tag vVERSION && git push`) | **absent** — rolling never pushes Git tags |
| Checkout ref / push branch | `main` | `rolling` |
| Cron | `32 * * * *` | `33 * * * *` |

- **Key YAML to copy (installer delta — cache step stays in both):**

```yaml
# rolling job1 (update-helium-rolling.yml L30-38) + job2 (L92-98):
# replace ONLY the installer line; keep the cache step identical to main.
- uses: cachix/install-nix-action@v31
  with:
    nix_path: nixpkgs=channel:nixpkgs-unstable
- uses: DeterminateSystems/flakehub-cache-action@main
```

- **Customization points:** Same table as §6.4, plus: decide deliberately whether
  to preserve or unify the installer divergence (see pitfalls §12). When
  replicating, keep the divergence unless you have a reason to converge — the
  spec is to replicate identically first, then converge as a separate change.

## 7. Shared Update-Script Contract (`.github/update-helium.sh`)

DRY lives here — both update workflows call the same script twice (check, then
update). The script is bespoke per upstream; copy the **contract**, adapt the
**upstream-specific** parts.

### 7.1 Contract (keep)

- **Interpreter:** POSIX `sh` (not bash). Executable bit set.
- **Flags:**
  - `--ci` — enable CI mode: run `nix flake update` (only flag combination that
    touches `flake.lock`) and append outputs to `$GITHUB_OUTPUT`.
  - `--only-check` — dry-run: compute whether an update is needed, emit outputs,
    exit without mutating `versions.nix` / `flake.lock`.
  - Typical invocations: `--ci --only-check` (gate step), then `--ci` (update step).
- **Outputs** (appended to `$GITHUB_OUTPUT` in `--ci` mode):
  - `should_update` — literal `true` / `false` string (consumed by `if:` gates
    and `test-build` gating).
  - `version` — the **semantic** version (`semantic_version`,
    `update-helium.sh` L117/L174): raw `remote_version` (upstream `tag_name`,
    e.g. `0.17.0.1`) piped through
    `sed 's/\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\.\([0-9][0-9]*\)$/\1-\2/'`
    so a trailing fourth component becomes `-N` (e.g. `0.17.0.1` → `0.17.0-1`).
    The tag step prepends `v` (`git tag v${{ steps.update.outputs.version }}`).
    `versions.nix` instead stores the **raw** `remote_version`
    (`write_versions_nix "$remote_version"`, L147-152), and the
    up-to-date comparison is raw-vs-raw
    (`[ "$local_version" = "$remote_version" ]`, L123). Do **not** document a
    leading-`v` strip — there is none.
  - `commit_message` — verbatim `chore(update): helium to ${semantic_version}`
    plus a blank line plus the `nix flake update` output when non-empty
    (`update-helium.sh` L164-172), consumed by `git-auto-commit-action`.
- **Env:**
  - `GH_TOKEN` — optional; when set (wired to `${{ github.token }}`), sent as
    `Authorization: Bearer` to raise `api.github.com` rate limits. Script must
    work **without** it (unauthenticated fallback).
- **Exit codes:** `0` on success (both “update available” and “already current”
  are success — distinguish via `should_update`, not exit code). Non-zero only
  on real errors (network/prefetch failure after retries, parse failure).
  `main()` runs under `set -e` (`update-helium.sh` L103), so any unhandled
  failing command aborts the script.
- **Dependencies:** `curl`, `jq`, `nix` (`nix store prefetch-file`), `git`.
- **Retry:** `with_retry` helper (`update-helium.sh` L17-40) — up to 5 attempts
  **only** when the command output contains `Not Found` (sleep 1 between tries,
  fail with `exit 1` after 5). Any other output returns immediately with the
  command's own status (fail-fast otherwise) after stripping control chars.
- **Nix commands used (only these):**
  - `nix store prefetch-file --hash-type sha256 --json` + `jq` (hash assets).
  - `nix flake update` — **only** when `--ci` is passed without `--only-check`
    **and** only on the update-needed path (after the L123 version mismatch;
    the `--only-check` gate and the already-current early exit at L123-129
    never touch `flake.lock`).
  - `nix build` is **never** run by the script (builds happen in workflow steps).

### 7.2 Adaptation guide (change per upstream)

1. **Release source:** `curl https://api.github.com/repos/<UPSTREAM-OWNER>/<UPSTREAM-REPO>/releases/latest`
   (+ `Authorization: Bearer $GH_TOKEN` when set).
2. **Tag parsing + semver transform:** `parse_field tag_name` gives the raw
   `remote_version` (e.g. `0.17.0.1`); derive `semantic_version` with the exact
   transform (`update-helium.sh` L117):
   `sed 's/\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\.\([0-9][0-9]*\)$/\1-\2/'`
   (e.g. `0.17.0.1` → `0.17.0-1`). Compare raw-vs-raw for `should_update`
   (L123); store raw in `versions.nix`; emit semantic as `version`
   (L174) for the tag (`v${version}`) and commit message. There is no
   leading-`v` strip.
3. **Asset list:** 4 prefetch targets here (2 architectures × 2 formats:
   `...-x86_64.AppImage`, `...-arm64.AppImage`, `...-x86_64_linux.tar.xz`,
   `...-arm64_linux.tar.xz`, built as `${download_base}/${remote_version}/helium-${remote_version}-<arch>.<ext>`,
   `update-helium.sh` L138-144). Replace with your upstream's asset names/URLs.
4. **Rewrite of `versions.nix`:** prefetch each asset's `sha256`, rewrite via
   `write_versions_nix` (`update-helium.sh` L84-100) as
   `{ version = "<raw remote_version>"; systems = { aarch64-linux = { appimage,
   tarball }; x86_64-linux = { appimage, tarball }; }; }` with bare hash
   strings. Keep `versions.nix` as the **sole** version source —
   `flake.nix` must read it (`data.version` / `data.systems`), never hardcode
   versions.
5. **Commit message:** verbatim `chore(update): helium to ${semantic_version}`
   (L167), plus a blank line plus the `nix flake update` stdout when non-empty
   (L168-171). The contract is that `commit_message` is emitted and consumed by
   the auto-commit step with `file_pattern: "*"`.

## 8. Nix Flake Contract

Minimal shape to replicate (full file here is 121 lines; keep it small):

```nix
{
  description = "Helium browser on Nix";  # replace with your description

  inputs = {
    # SINGLE input. Keep channel; lockfile pins the revision.
    # Exact case: lowercase `nixos` (flake.nix L6).
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      # versions.nix is the SOLE version source (mutated by CI).
      data = import ./versions.nix;   # flake.nix L13: data.systems
      version = data.version;
      baseUrl = "https://github.com/imputnet/helium-linux/releases/download/${version}";
      # inline system -> upstream-arch mapping (flake.nix L22-26), NOT a
      # separate archMap variable and NOT the opposite direction:
      #   arch = { "x86_64-linux" = "x86_64"; "aarch64-linux" = "arm64"; }.${system};
      # ... map over data.systems to produce per-system packages ...
    in {
      packages.x86_64-linux.helium-appimage = /* wrapType2 + fetchurl AppImage */;
      packages.x86_64-linux.helium-tarball  = /* mkDerivation + fetchurl tar.xz */;
      packages.aarch64-linux.helium-appimage = /* ... */;
      packages.aarch64-linux.helium-tarball  = /* ... */;
      packages.x86_64-linux.default = /* tarball */;
      packages.aarch64-linux.default = /* tarball */;
    };
}
```

Packaging specifics to preserve as patterns (full lists from `flake.nix`
L59-93 — do not truncate without marking):

| Package | Pattern |
|---|---|
| `helium-appimage` | `pkgs.appimageTools.wrapType2`-style AppImage wrapper; `fetchurl` with `baseUrl`, `pname`, `version`, arch suffix `.AppImage`; `hash = hashes.appimage`. |
| `helium-tarball` | `pkgs.stdenv.mkDerivation` + `fetchurl` `tar.xz` (`${pname}-${version}-${arch}_linux.tar.xz`); `hash = hashes.tarball`; `nativeBuildInputs`: `autoPatchelfHook`, `makeWrapper`, `kdePackages.wrapQtAppsHook` (with `kdePackages.` prefix); `buildInputs`: `stdenv.cc.cc.lib`, `alsa-lib`, `at-spi2-atk`, `at-spi2-core`, `atk`, `cairo`, `cups`, `dbus`, `expat`, `glib`, `gtk3`, `libGL`, `libxkbcommon`, `mesa`, `nspr`, `nss`, `pango`, `udev`, `libx11`, `libxcb`, `libxcomposite`, `libxdamage`, `libxext`, `libxfixes`, `libxrandr`, `kdePackages.qtbase`, `kdePackages.qtwayland` (adapt lib list to your binary). |
| `default` | Points at the tarball per system. |
| Arch mapping | Nix `x86_64-linux` → upstream `x86_64`; Nix `aarch64-linux` → upstream `arm64` (inline map keyed by `${system}`). |

`versions.nix` shape (exact — bare hash strings, no `assets`/`url` objects;
`versions.nix` L1-13, written by `update-helium.sh` L84-100, read via
`data.systems` / `hashes.appimage` / `hashes.tarball` in `flake.nix`):

```nix
{
  version = "0.17.0.1"; # raw upstream tag incl. trailing .N (see §7.2)
  systems = {
    aarch64-linux = {
      appimage = "sha256-..."; # bare nix hash string
      tarball = "sha256-...";
    };
    x86_64-linux = {
      appimage = "sha256-...";
      tarball = "sha256-...";
    };
  };
}
```

Rules:

- `flake.nix` never hardcodes a version — it imports `versions.nix`.
- CI mutates **only** `versions.nix` (+ `flake.lock` when `--ci` runs
  `nix flake update`). Never commit version bumps by hand alongside CI.
- `flake.lock` locks `nixos-unstable`; `nix flake update` runs **only** inside
  the script with `--ci` (never bare in YAML, never in `--only-check`).

## 9. Caching / Substituters Strategy

| Mechanism | Where | Purpose |
|---|---|---|
| `DeterminateSystems/flakehub-cache-action@main` | `build-helium.yml`, `update-helium-main.yml` (both jobs), `update-helium-rolling.yml` (both jobs: L36-38 job 1, L97-98 job 2) | FlakeHub binary cache / Nix store caching. Present in **both** update workflows — only the Nix *installer* diverges (Determinate on main/build vs `cachix/install-nix-action` on rolling). |
| `cachix/cachix-action@v17` (`name: <CACHE-NAME>`, `authToken: secrets.CACHIX_AUTH_TOKEN`) | `build-helium.yml`, both update workflows' job 1 (gated on `should_update == 'true'`) | Push/pull to the Cachix cache. Gate it behind the update check so no-cache work happens when there is nothing to do. |
| `cachix/install-nix-action@v31` (`nix_path: nixpkgs=channel:nixpkgs-unstable`) | `update-helium-rolling.yml` only | Alternative Nix installer (divergence preserved from source). |
| `include-output-paths: true` | Both FlakeHub publish workflows | Publishes built store paths to FlakeHub so downstream consumers hit cache. |

Copy rules:

- Keep the `should_update == 'true'` gate on installer/cache/update/commit/tag
  steps — installing Nix and pushing to Cachix on a no-op run wastes minutes.
- Keep `persist-credentials: false` on publish-workflow checkouts (least
  privilege; publish uses OIDC, not the checkout token).
- Do not add `substituters`/`trusted-public-keys` to `nix.conf` unless you are
  intentionally diverging — cache wiring here is action-based, not config-based.

## 10. Secrets / Permissions Matrix

| Secret | Used by | Wiring |
|---|---|---|
| `CACHIX_AUTH_TOKEN` (repo secret, required) | `build-helium.yml`, both update workflows | `authToken: '${{ secrets.CACHIX_AUTH_TOKEN }}'` in `cachix/cachix-action@v17`. Missing secret → Cachix step fails. |
| `GH_TOKEN` (not stored; built-in `github.token`) | Both update workflows' check step | `env: GH_TOKEN: ${{ github.token }}` for the `--only-check` curl. Raises API rate limit; script falls back to unauthenticated. |

| Workflow / job | Permissions | Why |
|---|---|---|
| `build-helium.yml` job | `id-token: write`, `contents: read` | OIDC for FlakeHub cache; read repo. |
| `flakehub-publish-rolling.yml` job | `id-token: write`, `contents: read` | OIDC for `flakehub-push`; read repo. |
| `flakehub-publish-tagged.yml` job | `id-token: write`, `contents: read` | Same. |
| `update-helium-main.yml` job 1 | `contents: write`, `id-token: write` | Push auto-commit + tag; OIDC for Determinate/FlakeHub cache. |
| `update-helium-rolling.yml` job 1 | `contents: write` only | Push auto-commit (no tag, Cachix installer needs no OIDC). Cache step still uses FlakeHub cache (no OIDC-gated installer). |
| `update-helium-main.yml` job 2 (`test-build`) | `contents: write`, `id-token: write` (`update-helium-main.yml` L91-93) | Build on the updated ref with Determinate + FlakeHub cache (needs OIDC). |
| `update-helium-rolling.yml` job 2 (`test-build`) | no permissions block (defaults) — the only job 2 without one | Read-only build on the updated ref with Cachix installer + FlakeHub cache. |
| Publish checkouts | `persist-credentials: false` | Do not persist `GITHUB_TOKEN` in the publish jobs. |

## 11. Branch / Tag Protection (recommended settings)

The source repo infers these requirements; apply them when replicating:

- **Branches `main` / `rolling` (and `<MAIN-BRANCH>` / `<ROLLING-BRANCH>`):**
  - Allow push from `github-actions[bot]` (or the repo's Actions identity) —
    otherwise `git-auto-commit-action` and the `git tag && git push` step are
    blocked. If you require PR reviews, add an exception for the bot or use a
    dedicated app token for the commit step.
  - Required checks (inferred): the `test-build` 4-matrix job should be required
    before merge/PR, so a bad upstream asset hash cannot land silently.
  - Hourly cron is staggered (`32` vs `33`) — keep the stagger so the two
    branches never rewrite shared state (`flake.lock`) concurrently.
- **Tags `v*`:**
  - Tag protection matching `v*` so only the `main` update workflow (and
    maintainers) can create version tags. Rolling must never create tags.
  - FlakeHub tagged publish triggers on `v?[0-9]+.[0-9]+.[0-9]+*` — keep tag
    protection and publish glob aligned.
- **General:**
  - `push: branches: [main]` re-triggers the update workflow via the bot's own
    commit; do not add `[skip ci]` — the `--only-check` gate already makes the
    second run a no-op. Blocking bot pushes breaks the loop; adding skip
    trailers breaks `test-build` gating.

## 12. Common Pitfalls

1. **Floating `@main` pins.** `determinate-nix-action@main`,
   `flakehub-cache-action@main`, and `flakehub-push@main` track a moving branch.
   Replicating identically means keeping them; hardening means pinning to a SHA
   or tag. Decide explicitly — do not “fix” one file and forget the other four.
2. **`checkout` v5 vs v6 drift.** `build-helium.yml` uses `actions/checkout@v5`;
   the other four workflows use `actions/checkout@v6`. Aligning to one version
   is safe but is a deliberate change — record it.
3. **`determinate-nix-action` main vs v3 drift.** Update-main/build use `@main`;
   both publish workflows use `@v3`. Same advice: preserve or align deliberately.
4. **Missing `id-token: write`.** FlakeHub publish, FlakeHub cache, and the
   Determinate installer need OIDC. Rolling job 1 drops `id-token` because it
   uses the Cachix installer (cache step itself is still
   `flakehub-cache-action@main`), and rolling job 2 has no permissions block
   while main job 2 keeps `contents: write` + `id-token: write`
   (`update-helium-main.yml` L91-93) — copying the wrong permissions block to
   the wrong job breaks auth in confusing ways.
5. **Bot push blocked.** `contents: write` is not enough if branch protection
   blocks the Actions bot. The symptom is a green update run with a red
   commit/tag step. Fix in branch settings, not YAML.
6. **Cron collision.** Both update workflows poll hourly. Running both at the
   same minute (`* * * * *` without stagger) risks concurrent `flake.lock` /
   `versions.nix` rewrites and double commits. Keep `32` vs `33` (or any
   ≥1-minute stagger).
7. **Rolling vs main installer divergence.** Rolling uses
   `cachix/install-nix-action@v31` + `nixpkgs=channel:nixpkgs-unstable`; main
   uses Determinate. Both keep `flakehub-cache-action@main` in both jobs
   (rolling L36-38, L97-98) — only the installer diverges. Unifying is tempting
   but changes cache behavior and OIDC requirements — treat as a migration, not
   a copy fix.
8. **Tag step copied to rolling.** Rolling must not `git tag`/`git push` tags.
   A stray tag step on rolling creates version tags the publish workflow will
   pick up as releases.
9. **`nix flake update` in the wrong place.** It must run only inside
   `update-helium.sh` under `--ci` without `--only-check`. Running it in YAML,
   in `--only-check`, or on every build defeats the `should_update` gate and
   dirties `flake.lock` on no-op runs.
10. **Editing `versions.nix` by hand.** It is the CI-owned sole version source.
    Hand edits race with the hourly job and get overwritten or cause
    `should_update` flapping. Change the script's asset list instead.
11. **No lint/format safety net.** There is no `nixfmt`/`statix`/`flake check`.
    A malformed `versions.nix` rewrite fails at `nix build` in `test-build` —
    watch that job, not a lint job that does not exist.

## 13. Replication Steps (ordered 1–10)

1. **Copy the file tree.** Copy `.github/workflows/*.yml` (5 files),
   `.github/update-helium.sh` (preserve executable bit), `flake.nix`,
   `versions.nix`, `flake.lock`. Verify no extra CI files (see §5 absence list).
2. **Rename placeholders.** Replace `<OWNER>/<REPO>` paths,
   `<FLAKEHUB-NAME>` in both publish workflows, `<CACHE-NAME>` in build + both
   update workflows, `<UPSTREAM-OWNER>/<UPSTREAM-REPO>` + asset URLs in
   `update-helium.sh`, branch names in triggers/checkout refs, and package names
   in matrices + `flake.nix` outputs.
3. **Adapt the update script (bespoke part).** Update the releases API URL,
   tag parsing + semver transform (`sed` trailing `.N` → `-N`), the 4 (or N)
   asset URLs, the `versions.nix`
   rewrite, and the `commit_message` text. Keep flags (`--ci`, `--only-check`),
   outputs (`should_update`, `version`, `commit_message`), `GH_TOKEN` handling,
   `with_retry` (5x on `Not Found` only, fail-fast otherwise), and the
   `nix store prefetch-file` + conditional
   `nix flake update` contract (§7).
4. **Adapt the flake (minimal).** Keep single-`nixpkgs` input +
   `versions.nix`-as-sole-source pattern; swap `helium-appimage` /
   `helium-tarball` derivations and `buildInputs` for your packages; keep
   `default` and the arch map semantics (§8).
5. **Set secrets.** Create repo secret `CACHIX_AUTH_TOKEN` (Cachix token for
   `<CACHE-NAME>`). Confirm no other stored secret is needed (`GH_TOKEN` comes
   from `github.token` at runtime).
6. **Set permissions.** Apply the matrix in §10 verbatim (including the rolling
   job 1 “no `id-token`” delta, the main-job-2-has / rolling-job-2-has-none
   delta, and `persist-credentials: false` on publish checkouts).
7. **Configure branches/tags.** Create `<MAIN-BRANCH>` / `<ROLLING-BRANCH>`;
   allow bot push; require `test-build` checks; protect tags `v*`; stagger cron
   (`32` vs `33` or equivalent) (§11).
8. **Verify manual build.** Dispatch `build-helium.yml` (`gh workflow run
   build-helium.yml`) and confirm all 4 matrix jobs `nix build` successfully.
9. **Verify update loop + publishing.** Push an empty commit to each branch and
   confirm: (a) `--only-check` no-op path skips update steps; (b) forcing an
   update (or dispatching) commits `versions.nix`, tags `v*` on main only, runs
   `test-build`, and triggers FlakeHub rolling publish; (c) pushing a
   `v0.0.0-test`-style tag (or dispatching `flakehub-publish-tagged.yml` with
   `tag:`) triggers a tagged publish. Delete test tags afterwards.
10. **Enable the hourly schedule and watch one cycle.** Confirm the cron fires
    (Actions → each update workflow → “scheduled”), the check step uses
    `GH_TOKEN`, and a no-change hour exits green with update steps skipped and
    no commit/tag/publish. Only then consider the replication complete.

## Appendix: Pin Inventory (do not “update” during replication)

| Component | Pin in this repo |
|---|---|
| `actions/checkout` | `v5` (build-helium) vs `v6` (all others) |
| `DeterminateSystems/determinate-nix-action` | `@main` (build + update-main) vs `@v3` (publish ×2) |
| `DeterminateSystems/flakehub-cache-action` | `@main` |
| `DeterminateSystems/flakehub-push` | `@main` |
| `cachix/cachix-action` | `@v17` (`name: x13` → `<CACHE-NAME>`) |
| `cachix/install-nix-action` | `@v31` (rolling only) |
| `stefanzweifel/git-auto-commit-action` | `@v7` |
| `nixpkgs` | `nixos-unstable`, locked in `flake.lock` |
| Runners | `ubuntu-24.04`, `ubuntu-24.04-arm`, `ubuntu-latest` |
| `update-helium.sh` deps | `curl`, `jq`, `nix`, `git` |

---

*Generated from verified exploration of `helium-nix` (GitHub Actions only,
5 workflows + helper + `flake.nix`/`versions.nix`/`flake.lock`). Replicate
identically first; diverge deliberately afterwards.*
