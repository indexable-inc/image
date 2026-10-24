/**
The POSIX sh that bounds dirty pages on a zoned segvol root, from ./shared.nix `zonedRootWriteback`. It reads the root's
mount options from `<proc>/mounts` and writes the two sysctls only when `/` has a realtime device (`rtdev=`); on any
other root it changes nothing. Plain sh with no tools, so the NixOS guest (nix/lib/os/image.nix) and the runner
entrypoint (build/images/runner/entrypoint, a committed copy checked by root//:zoned-root-writeback-test) run the same
text.

`proc` is the procfs mount: "/proc" in an image, a fake tree in the test. Returns the script as a string.
*/
{proc}: let
  bounds = (import ./shared.nix).zonedRootWriteback;
in ''
  root_opts=
  while read -r _ mnt _ opts _; do
    if [ "$mnt" = / ]; then root_opts=$opts; fi
  done < ${proc}/mounts
  case ",$root_opts," in
    *,rtdev=*)
      echo ${toString bounds.dirtyBackgroundBytes} > ${proc}/sys/vm/dirty_background_bytes
      echo ${toString bounds.dirtyBytes} > ${proc}/sys/vm/dirty_bytes
      ;;
  esac
''
