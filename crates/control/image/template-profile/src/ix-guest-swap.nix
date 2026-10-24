# Guest swap posture, declared with the stock NixOS `zramSwap` options and
# translated into `/etc/ix/guest-swap.toml` -- the one file the ix guest daemon
# reads to decide what swap a VM gets
# (crates/vm/guest/daemon/src/handler/swap/config.rs).
#
# Nothing about swap crosses the host/guest wire: the image declares it, the
# declaration travels inside the snapshot with the userland it describes, and
# the daemon reads it at `Configure`. This module is the whole translation
# layer between what an image AUTHOR writes and what the daemon READS.
#
# # Why the stock options and not an `ix.*` option of our own
#
# Every NixOS user already knows `zramSwap.enable`, every existing template
# that wanted compressed swap already sets it, and an ix-specific spelling
# would mean a template author has to write ix's dialect to get the behaviour
# their own dialect already describes. So the stock options ARE the surface:
# an unmodified NixOS configuration that says `zramSwap.enable = true` gets
# what it asked for, delivered by the daemon rather than by zram-generator.
#
# # Why this file lives in a Rust crate's `src/`
#
# It has two consumers that share no reachable directory:
#
#   * the ix base image, which imports it by path
#     (nix/packages/blockvol-base-artifact.nix), and
#   * every user template, which receives it as a FILE written into the build
#     guest next to the wrapper flake -- so its bytes have to be embedded in
#     the node-agent binary with `include_str!`.
#
# The Rust build's source fileset is `<crate>/{Cargo.toml,src,tests,...}` and
# nothing else (index/lib/rust/workspace.nix), so a module under `nix/` is not
# in the sandbox when the crate compiles and `include_str!` cannot reach it.
# `src/` next to `ix-machine-profile.nix` -- which is here for exactly this
# reason and says so -- is the only directory both consumers can read. One
# file, no twin, no drift fence.
#
# # The tri-state, and why it is read from PRIORITIES
#
#   author wrote nothing            -> mode = "default"  (platform defaults)
#   author wrote `enable = true`    -> mode = "custom"   (their knobs)
#   author wrote `enable = false`   -> mode = "off"      (daemon touches nothing)
#
# The middle and last rows are the point: an image must be able to opt OUT as
# reliably as it opts in. That is impossible to read off the option's VALUE,
# because `zramSwap.enable` has `default = false` upstream -- so "the author
# disabled it" and "the author never mentioned it" are the same `false` and
# would both have to mean the same thing.
#
# They are distinguishable one layer down, but NOT by `isDefined`, which is the
# obvious answer and is wrong. A nixpkgs option `default` is not merely a
# fallback the module system consults if nothing else matched: it is
# materialized as a real definition, wrapped in `mkOptionDefault` and
# attributed to the file that DECLARED the option. So `isDefined` is true for
# every declared option in every evaluation, whether or not anyone wrote
# anything, and a module reading it sees every knob as authored. Measured on
# the pinned nixpkgs (rev e2587caef70c): in a bare NixOS eval,
# `options.zramSwap.memoryPercent.isDefined` is `true`, its one definition is
# `50`, and its `files` names `nixos/modules/config/zram.nix` -- the
# declaration site, not a config site.
#
# What actually separates an author's statement from a nixpkgs default is the
# PRIORITY of the winning definitions, which the option surfaces as
# `highestPrio` (nixpkgs lib/modules.nix: `inherit (res.defsFinal') highestPrio`
# on the option attrs; `mkOptionDefault = mkOverride 1500`, `mkDefault = 1000`,
# a plain `x = y` is 100, `mkForce` is 50). An untouched option sits at 1500;
# anything an author wrote outranks it. That is the exact distinction the
# tri-state needs, and it is why this module takes `options` as well as
# `config`.
#
# The same mechanism is used per knob: only knobs the author actually defined
# are emitted, and everything unstated falls through to the daemon's platform
# default. An image overriding one knob does not have to restate the others,
# and it does not silently inherit nixpkgs' defaults for the ones it left
# alone (upstream's `priority = 5`, for one, is not ix's `100`).
#
# # Two traps this module makes unrepresentable
#
# Both are silent: the daemon's fail-safe rule resolves an unreadable file to
# "no swap at all", so a malformed declaration does not fail a build -- it
# ships an image whose every VM quietly runs without swap.
#
#   1. `version` must be 1, and `mode` must be one of exactly three strings.
#      Anything else is refused by the daemon. Here `version = 1` is a literal
#      in a constant string that interpolates nothing, and the mode is picked
#      by indexing a three-entry attrset with the tri-state -- so a fourth
#      posture added without a rendering is an eval error, not a bad file.
#
#   2. `[zram].max` must be ABSOLUTE. A percentage there is refused outright
#      (a percentage cap on a percentage size says nothing the size does not),
#      which parks swap for the whole image. Here `max` can only ever come
#      from `zramSwap.memoryMax`, which upstream types as bytes, so a
#      percentage cannot reach that field by any input.
#
# A third one, found while writing this: `max = "0"` is the daemon's spelling
# for UNCAPPED. Byte-to-MiB is integer division, so a `memoryMax` under 1 MiB
# would floor to `0` and turn the tightest possible cap into no cap at all --
# the exact inversion of intent. The assertion below refuses it instead.
#
# Everything this module emits is range-checked against what the daemon can
# parse, by loud eval assertions rather than by clamping. A clamp would mean
# the image quietly running something other than what it declared; an
# out-of-range value that reaches the file means no swap at all, for every VM
# built from the image. Failing the build is the only outcome that is neither.
#
# # What is deliberately not translated
#
#   * `zramSwap.writebackDevice` -- the daemon has no writeback tier. Omitted
#     without comment in the rendered file (there is no honest way to spell it).
#   * `zramSwap.swapDevices` -- the daemon makes exactly one device. A count
#     other than 1 is not honoured.
#   * top-level `swapDevices` (on-disk swap) -- the daemon's disk tier stays
#     dormant; it writes billed bytes to a customer volume and is opt-in only.
#   * `boot.kernel.sysctl."vm.swappiness"` -- swappiness stays platform-owned.
#     An image setting the sysctl directly has it applied by NixOS at
#     activation and then overwritten by the daemon at `Configure`.
{
  config,
  lib,
  options,
  ...
}: let
  cfg = config.zramSwap;

  # The priority the module system gives an option's own `default`. Derived
  # from `mkOptionDefault` rather than spelled `1500`, so it cannot drift from
  # the number nixpkgs actually uses.
  optionDefaultPriority = (lib.mkOptionDefault null).priority;

  # Did the image author state this knob, as opposed to inheriting nixpkgs'
  # default for it? See the header: `isDefined` cannot answer this (it is true
  # for every declared option), and the priority can.
  declared = option: option.highestPrio < optionDefaultPriority;

  bytesPerMib = 1024 * 1024;

  # The tri-state. Read from whether a definition EXISTS, then from its value;
  # see the header for why the value alone cannot carry this.
  posture =
    if !(declared options.zramSwap.enable)
    then "default"
    else if cfg.enable
    then "custom"
    else "off";

  # Only what the author actually wrote. An unstated knob is absent from the
  # file, and the daemon fills it from the platform default.
  zramLines =
    lib.optional (declared options.zramSwap.memoryPercent) ''size = "${toString cfg.memoryPercent}%"''
    ++ lib.optional (
      declared options.zramSwap.memoryMax && cfg.memoryMax != null
    ) ''max = "${toString (cfg.memoryMax / bytesPerMib)}"''
    # `builtins.toJSON` of a string is a TOML basic string: it escapes the
    # backslash, the quote and the control characters, and emits nothing TOML
    # rejects. The algorithm is `either (enum [...]) str` upstream, so it is
    # attacker-shaped input as far as this file is concerned -- an unescaped
    # quote would break the TOML and park swap for the whole image.
    ++ lib.optional (declared options.zramSwap.algorithm) "algorithm = ${builtins.toJSON cfg.algorithm}"
    ++ lib.optional (declared options.zramSwap.priority) "priority = ${toString cfg.priority}";

  header = ''
    # Generated by the ix guest swap module from this image's `zramSwap`
    # options; read by the ix guest daemon. Do not edit in a running guest:
    # it is a read-only store symlink and the daemon re-reads it on every
    # Configure.
    version = 1
  '';

  # Indexing this attrset is what makes an unknown mode unrepresentable: a
  # posture with no rendering here is an eval error, never a file the daemon
  # refuses. The three keys are the three the daemon understands, spelled once.
  rendered = {
    default = ''
      ${header}mode = "default"
    '';
    off = ''
      ${header}mode = "off"
    '';
    custom = ''
      ${header}mode = "custom"

      [zram]
      ${lib.concatStringsSep "\n" (["enable = true"] ++ zramLines)}
    '';
  };
in {
  config = {
    # The declaration itself. `mkDefault` so an author who hand-writes this
    # exact file wins outright rather than colliding with us: their bytes are
    # the most specific statement of intent there is, and an eval conflict
    # would be a worse answer than honouring it.
    environment.etc."ix/guest-swap.toml".text = lib.mkDefault rendered.${posture};

    # The stock generator, off in every ix guest, unconditionally.
    #
    # `zramSwap.enable = true` upstream does exactly one thing: it turns on
    # `services.zram-generator` and writes it a settings block
    # (nixpkgs nixos/modules/config/zram.nix). Left alone, the generator would
    # create and swapon its own zram0 from `/etc/systemd/zram-generator.conf`
    # at boot -- sized against the guest's CURRENT memory, which for a
    # virtio-mem guest is the small boot base and not the ceiling it will run
    # with -- while the daemon creates and sizes the device it was told to.
    # Two owners, one `/dev/zram0`. Disabling it here is what makes the stock
    # options a DECLARATION that ix implements, rather than a second
    # implementation racing ours.
    #
    # Unconditional, and not gated on the tri-state: a guest that enables the
    # generator directly, without going through `zramSwap`, is the same
    # collision wearing a different hat. Swap in an ix guest has one owner.
    services.zram-generator.enable = lib.mkOverride 50 false;

    # Every emitted value has to be inside what the daemon can parse. A value
    # that is not does not degrade: the file fails to deserialize, the daemon
    # applies its fail-safe, and every VM from this image runs with no swap at
    # all and nothing in the build to say why.
    assertions = [
      {
        assertion = !(declared options.zramSwap.priority) || (cfg.priority >= 0 && cfg.priority <= 65535);
        message = ''
          zramSwap.priority is ${toString cfg.priority}, which ix cannot express: the guest
          swap declaration carries the priority as a u16 (0-65535), and a value outside that
          range makes /etc/ix/guest-swap.toml unparseable -- which the guest daemon fail-safes
          to NO SWAP AT ALL, silently, on every VM built from this image.
        '';
      }
      {
        assertion = !(declared options.zramSwap.memoryPercent) || cfg.memoryPercent <= 65535;
        message = ''
          zramSwap.memoryPercent is ${toString cfg.memoryPercent}. ix caps a zram device at
          200% of the VM's memory ceiling (zram stores compressed, so above 100% is
          legitimate; far above it only widens the window in which the guest fills RAM with
          compressed pages and OOMs). A percentage this large is a typo, not a request.
        '';
      }
      {
        assertion =
          !(declared options.zramSwap.memoryMax)
          || cfg.memoryMax == null
          || cfg.memoryMax >= bytesPerMib;
        message = ''
          zramSwap.memoryMax is ${toString cfg.memoryMax} bytes, which is under 1 MiB.
          ix expresses the cap in MiB, so this would floor to 0 -- and 0 is the guest
          daemon's spelling for NO CEILING. The tightest cap you can write would become no
          cap at all. State at least ${toString bytesPerMib} (1 MiB), or leave memoryMax
          unset for the platform default.
        '';
      }
    ];
  };
}
