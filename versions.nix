# Machine-updated by .github/update-openchamber.sh — do not edit by hand.
{
  version = "1.24.1";
  rev = "d54d57c09e783409bbce79ee9ea2d75e346ca807";
  srcHash = "sha256-o57LYgDkbjamxkLSrxOaZ8/PhRYMHgIDTV1oqKAB8/8=";
  # Upstream-expected opencode CLI version: the packages/web
  # @opencode-ai/sdk pin (tracks the CLI release line; the server has no
  # separate binary-version gate). Maintained by
  # .github/update-openchamber.sh; drives the opencodePackage skew warning.
  opencodeVersion = "1.18.31";
  systems = {
    x86_64-linux = {
      arch = "x86_64";
      appimage = "sha256-+8Uqla4zwz8hDtc0lHM81kGKsUF36lksNLYqRd4oWCQ=";
    };
    aarch64-linux = {
      arch = "arm64";
      appimage = "sha256-ejLd/OEb3jppGCKlXTwWH0p8O2sxl6RukUic9d/n5Ho=";
    };
  };
}
