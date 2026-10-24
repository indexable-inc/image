/**
btop from the public fork github.com/indexable-inc/btop: upstream main plus `theme_mode = "Auto"`, which picks
color_theme_dark or color_theme_light from the terminal's OSC 11 background color (indexable-inc/btop#1). The fork
keeps upstream's defaults; ix/base turns the mode on in nix/modules/guest/btop.conf, and the image build checks it
there (btop_conf_check.py), so a stock btop fails that build.

Argument: `src`, the fork's source tree. ix passes the `views/btop` Gitlink (lib/nixpkgs-overlays.nix); the public
image mirror fetches the same revision from GitHub. Returns an overlay.
*/
{src}: _: prev: {
  btop = prev.btop.overrideAttrs {
    version = "1.4.7-unstable-2026-10-20";
    inherit src;
    # The fork's binary still prints upstream's version, which
    # versionCheckHook compares against $version.
    preVersionCheck = "version=1.4.7";
  };
}
