/**
btop from the public fork github.com/indexable-inc/btop: upstream main plus `theme_mode = "Auto"`, which picks
color_theme_dark or color_theme_light from the terminal's OSC 11 background color (indexable-inc/btop#1). The fork
keeps upstream's defaults; ix/base turns the mode on in nix/modules/guest/btop.conf, and the image build checks it
there (btop_conf_check.py), so a stock btop fails that build.

Argument: `src`, the fork's source tree. ix passes the `views/btop` Gitlink (lib/nixpkgs-overlays.nix); the public
image mirror fetches the same revision from GitHub. Returns an overlay.

The version is the one the fork's binary prints (`const string Version` in src/btop.cpp), read from `src`, since
versionCheckHook fails the build unless `btop --version` prints $version. A tree that declares it other than once
fails evaluation.
*/
{src}: let
  source = "${src}/src/btop.cpp";
  lines = builtins.filter builtins.isString (builtins.split "\n" (builtins.readFile source));
  declared = builtins.filter (found: found != null) (map (builtins.match ''[[:space:]]*const string Version = "([^"]+)";'') lines);
  version =
    if builtins.length declared == 1
    then builtins.head (builtins.head declared)
    else throw "btop-overlay.nix: ${source} declares `const string Version = \"...\";` ${toString (builtins.length declared)} times, not once";
in
  _: prev: {
    btop = prev.btop.overrideAttrs {
      inherit src version;
    };
  }
