/**
The NixOS modules that make ix/base, the guest image ix VMs boot, in evaluation order.

ix evaluates `os` in nix/lib/os/image.nix and appends `guest` in nix/packages/blockvol-base-artifact.nix
`guestToplevelFor`. The public mirror github.com/indexable-inc/image imports both lists as `nixosModules.base`
(satellites/image/flake.nix), so this file is the one composition both read. Order is part of the image: list
options such as `environment.systemPackages` merge in module order, and reordering changes the toplevel.

Returns `{ os; guest; }`, two functions from arguments to a list of NixOS modules:

- `os { nixpkgs, nixRoot, imageRuntimeModule }`: the base OS. `nixpkgs` is the locked nixpkgs flake input the
  image pins, `nixRoot` the `nix/` directory, `imageRuntimeModule` the template profile's ix-guest-runtime.nix.
- `guest { nixRoot, repoRoot, ixSecrets, ixOpen, flox, blockvol }`: the guest policy and tools layered on it.
  `ixSecrets` and `ixOpen` are ix's static-musl guest binaries (crates/vm/guest/secrets-client,
  crates/vm/guest/open), `flox` the flox CLI package, `blockvol` the arguments of
  nix/packages/blockvol-guest-system.nix.

Neither list sets `nix.package`; ix sets its own Nix build beside them (nix/lib/os/image.nix).
*/
{
  os = {
    nixpkgs,
    nixRoot,
    imageRuntimeModule,
  }: [
    (nixRoot + "/modules/guest/platform.nix")
    (nixRoot + "/modules/guest/dbus-survives-mount-removal.nix")
    (nixRoot + "/modules/guest/tmp-stays-writable.nix")
    (nixRoot + "/modules/guest/fast-linker.nix")
    (nixRoot + "/modules/guest/fast-coreutils.nix")
    imageRuntimeModule
    (import (nixRoot + "/lib/os/image-module.nix") {inherit nixpkgs nixRoot;})
  ];

  guest = {
    nixRoot,
    repoRoot,
    ixSecrets,
    ixOpen,
    flox,
    blockvol,
  }: [
    (import (nixRoot + "/packages/blockvol-guest-system.nix") blockvol)
    # The boot-then-capture ordering points (ENG-12384): every ix guest gets
    # the vocabulary, so a unit anywhere can declare which side of the
    # capture cut it belongs on, and the post-restore eval gate applies here
    # too.
    #
    # The legacy disk base leaves captureMode false. A directly published
    # native image opts in through extraModules; mkImageRoot then mirrors
    # its marker into the manifest the host actually scans. Enabling it
    # globally would split the legacy host and guest protocols (ENG-12402).
    (nixRoot + "/modules/guest/golden.nix")
    # Swap posture: not block-volume policy, it is what any ix guest needs.
    # The base image declares no `zramSwap` options at all, which is exactly
    # how it asks for the platform defaults: the module reads intent from
    # whether a definition EXISTS, so saying nothing here is the declaration.
    (repoRoot + "/crates/control/image/template-profile/src/ix-guest-swap.nix")
    ({pkgs, ...}: import (nixRoot + "/packages/ix-agent-tools.nix") {inherit pkgs ixSecrets;})
    (import (nixRoot + "/modules/guest/ix-open.nix") {inherit ixOpen;})
    # First-login terminal: zsh + starship, toolbox, truecolor, the `ix` user.
    (nixRoot + "/modules/guest/ix-terminal.nix")
    # The flox CLI (GPL-2.0, a separate executable).
    {environment.systemPackages = [flox];}
  ];
}
