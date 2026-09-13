# `formatter.<system>`: treefmt multiplexing nixfmt + deadnix + statix +
# keep-sorted. Single-input friendly: everything comes from nixpkgs via
# `treefmt.withConfig` (no extra flake inputs to lock).
#
# Run `nix fmt` to format, `nix fmt -- --ci` (or `treefmt --ci`) to check.
{
  treefmt,
  nixfmt,
  deadnix,
  statix,
  keep-sorted,
  writeShellScriptBin,
}:
let
  # `statix fix` accepts a single target, but treefmt passes every matched
  # file at once — fan out to one invocation per file.
  statixFixAll = writeShellScriptBin "statix-fix-all" ''
    for target in "$@"; do
      ${statix}/bin/statix fix "$target" || exit 1
    done
  '';
in
treefmt.withConfig {
  runtimeInputs = [
    deadnix
    keep-sorted
    nixfmt
    statix
  ];
  settings = {
    # treefmt discovers the repo root via git; in CI pin it explicitly:
    # `treefmt --tree-root-file flake.nix --ci` (see `checks` + check.yml).
    global.excludes = [
      ".direnv/*"
      "out/*"
      "result*"
    ];
    formatter = {
      deadnix = {
        command = "${deadnix}/bin/deadnix";
        options = [ "--edit" ];
        includes = [ "*.nix" ];
      };

      keep-sorted = {
        command = "${keep-sorted}/bin/keep-sorted";
        includes = [ "*.nix" ];
      };

      nixfmt = {
        command = "${nixfmt}/bin/nixfmt";
        includes = [ "*.nix" ];
      };

      statix = {
        command = "${statixFixAll}/bin/statix-fix-all";
        includes = [ "*.nix" ];
      };
    };
  };
}
