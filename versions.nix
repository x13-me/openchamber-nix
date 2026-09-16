# Machine-updated by .github/update-openchamber.sh — do not edit by hand.
{
  version = "1.23.1";
  webHash = "sha256-QrfCU3EpBPlI3OFLcsZIxSW0cHlzBejMbgzxESEW+tw=";
  # Opencode CLI release-line pin: the published web tarball's
  # @opencode-ai/sdk pin (informational basis for the major-skew warning;
  # the server declares no minimum CLI version). Maintained by
  # .github/update-openchamber.sh; drives the opencodePackage major-skew
  # warning.
  opencodeVersion = "1.18.30";
  systems = {
    x86_64-linux = {
      arch = "x86_64";
      appimage = "sha256-IsV9melcCm3QMqs7N+hP/YCKBM6fERgIhgyq3ZL4qoc=";
      nodeModules = "sha256-xshmMQrBJX/Bhe4qudEjO2GRkod5dvha8gKqOqlcEw8=";
    };
    aarch64-linux = {
      arch = "arm64";
      appimage = "sha256-wZqNMMFz7qeH1UbY+NOOppOMW1V9dZuPQvIPoDrMB7Q=";
      nodeModules = "sha256-fFvmDsTRnmeXpuE3tCStfWxc5K26qZCd/WG/tT8aqVY=";
    };
  };
}
