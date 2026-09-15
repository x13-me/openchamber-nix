# Thin flake root: all outputs live in `./nix` (see `nix/default.nix`).
{
  description = "OpenChamber on Nix";

  # Binary cache: CI pushes every updater test-build here (see README
  # "Binary cache"). The public key is trusted out-of-band — the owner
  # adds `trusted-public-keys = [ "x13.cachix.org-1:<key>" ];` below.
  nixConfig = {
    extra-substituters = [ "https://x13.cachix.org" ];
  };

  inputs = {
    # Channel tarball instead of `github:NixOS/nixpkgs/nixos-unstable` saves
    # ~15MB on every fetch: the tarball fetcher downloads only nixexprs,
    # while the GitHub fetcher clones full git history metadata.
    # If the channel infra ever fails to lock, fall back to:
    #   nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
  };

  outputs = inputs: import ./nix inputs;
}
