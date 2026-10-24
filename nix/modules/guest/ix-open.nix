# The guest browser helper `ix-open` (crates/vm/guest/open) as the system profile's
# `xdg-open` and `BROWSER`, so `claude login` and `gh auth login --web` open on the attached
# `ix` client's machine from any shell: login and non-login, cron, systemd user services.
# NixOS's set-environment rebuilds PATH for every login shell, which drops ix-console's
# /run/ix/bin script, so the profile has to carry the opener itself. ix-console's script still
# runs /run/current-system/sw/bin/ix-open (crates/vm/guest/console/agent/src/local_open.rs
# `IMAGE_HELPER`). The binary lives in the image's store, never in a VM's tmpfs.
#
# Layered by blockvol-base-artifact.nix `guestToplevelFor`; build/images `ix-open-boot` boots
# it with the real ix-console. An image without this module still opens URLs from a non-login
# session shell, through ix-console's script and the terminal escape it falls back to.
#
# `ixOpen` is the static-musl `ix-open` guest binary (`guestBins.ix-open`), with
# `meta.mainProgram`.
{ixOpen}: {
  lib,
  pkgs,
  ...
}: let
  xdgOpen = pkgs.runCommandLocal "ix-open-xdg-open" {} ''
    mkdir -p "$out/bin"
    ln -s ${lib.getExe ixOpen} "$out/bin/xdg-open"
  '';
in {
  # hiPrio: a package that pulls in xdg-utils must not decide which xdg-open the profile links.
  environment.systemPackages = [ixOpen (lib.hiPrio xdgOpen)];
  # set-environment exports it unconditionally, so a login shell replaces a BROWSER the session forwarded.
  environment.sessionVariables.BROWSER = "/run/current-system/sw/bin/xdg-open";
}
