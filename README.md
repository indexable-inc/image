# ix image

ix/base, the NixOS image every ix VM boots, as a NixOS module you can import and extend.

This repository is generated from [indexable-inc/ix](https://ix.dev) on every ix release that changes the image. The publisher never force-pushes and refuses to build on a commit it did not write. Issues and pull requests are closed, and changes land in ix.

## Use it

```nix
{
  inputs.ix-image.url = "github:indexable-inc/image";
  inputs.nixpkgs.follows = "ix-image/nixpkgs";

  outputs = {nixpkgs, ix-image, ...}: {
    nixosConfigurations.my-vm = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux"; # or aarch64-linux
      modules = [
        ix-image.nixosModules.base
        ({pkgs, ...}: {
          # Outside ix, any package with these binaries; on ix, the platform's own.
          ix.base.ixSecrets = pkgs.writeShellScriptBin "ix-secrets" "echo 'no ix secrets here' >&2; exit 1";
          ix.base.ixOpen = pkgs.writeShellScriptBin "ix-open" ''exec ${pkgs.xdg-utils}/bin/xdg-open "$@"'';
        })
        ./my-vm.nix
      ];
    };
  };
}
```

`nixpkgs.follows` keeps your system on the nixpkgs revision ix/base was built and tested with. Drop it and the module still evaluates against yours, untested.

Extend it the way you extend any NixOS module: add modules after `nixosModules.base`. List options such as `environment.systemPackages` and `services.*.settings` merge with the image's; a scalar the image sets needs `lib.mkForce` to replace.

The module adds one overlay, btop from [indexable-inc/btop](https://github.com/indexable-inc/btop), which the image's btop config needs; `ix-image.overlays.default` is the same overlay for other package sets. If you build the system from your own `nixpkgs.pkgs`, NixOS refuses the module's `nixpkgs.config`, so allow the unfree `claude-code` package when you import nixpkgs.

## What it contains

Files sit at their ix paths, so a path named in a comment is the same file here and in ix. `nix/modules/guest/base.nix` lists the modules in the order ix evaluates them. `nix/modules/guest/platform.nix` turns the module loader back on because the ix host boots the kernel and adds its modules to the root filesystem; `platform.md` gives the reason for each setting. The `golden.nix`, `tmp-stays-writable.nix`, `dbus-survives-mount-removal.nix`, `nix/packages/blockvol-guest-system.nix` and `crates/control/image/template-profile` modules hold the snapshot ordering, swap, user publication and block-volume root policy that ix's VM lifecycle relies on. The rest is the user environment: zsh, a developer toolbox, Claude Code and Codex at pinned versions, mold as the Rust linker, the flox CLI, and caches cache.ix.dev, cache.nixos.org and cache.flox.dev with their keys.

## What it leaves out

- The kernel. ix boots its own kernel build directly and copies that kernel's modules into the image root; neither is in this tree.
- The guest agent and daemon. The image's init (`remote-bootstrap`) receives them from the host over vsock at boot. `ix.base.ixSecrets` and `ix.base.ixOpen` are the two ix binaries the module installs, and you supply them.
- ix's Nix build. ix/base sets `nix.package` to it; this module leaves the NixOS default.
- A binary cache for your system. Paths from nixpkgs substitute from cache.nixos.org, and the module trusts cache.ix.dev, which may hold paths ix built for the image. Nothing promises either for your configuration; what neither has builds from source.

## Versions

Each commit names the ix commit it was generated from in its `Source-Commit:` trailer, and is tagged `ix-<first 12 hex digits of that commit>`. Pin a tag to get the image of one ix release:

```nix
inputs.ix-image.url = "github:indexable-inc/image/ix-0123456789ab";
```

The kernel and the guest agent come from the ix host the VM runs on. `platform.nix` and the snapshot modules assume the host's behaviour at the tagged release, so on ix, use the tag that matches the release your host runs.

## License

Apache-2.0 ([LICENSE](LICENSE)); [NOTICE](NOTICE) covers third-party software and the ix and Indexable trademarks.
