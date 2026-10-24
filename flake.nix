{
  description = "ix's NixOS base image (ix/base) as a NixOS module. Generated from indexable-inc/ix; changes land there.";

  # Both pins are ix's own: flake.lock is the matching subgraph of ix's flake.lock, written on every publish.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flox.url = "github:flox/flox/v1.18.1";
  };

  outputs = {
    nixpkgs,
    flox,
    ...
  }: let
    # The btop fork's revision, from ix's `views/btop` Gitlink (pins.json is generated with this tree).
    pins = builtins.fromJSON (builtins.readFile ./pins.json);
    btopOverlay = import ./lib/btop-overlay.nix {
      # astlog-ignore: no-builtins-fetch -- the rev is ix's views/btop Gitlink commit, which fixes the tree; a pkgs.* fetcher needs a content hash ix records for no Gitlink
      src = builtins.fetchGit {
        inherit (pins.btop) url rev;
        shallow = true;
      };
    };
    composition = import ./nix/modules/guest/base.nix;
    nixRoot = ./nix;
  in {
    # ix/base's change to nixpkgs: btop from the fork, which nix/modules/guest/btop.conf needs.
    overlays.default = btopOverlay;

    nixosModules.base = {
      config,
      lib,
      options,
      pkgs,
      ...
    }: {
      imports =
        composition.os {
          inherit nixpkgs nixRoot;
          imageRuntimeModule = ./crates/control/image/template-profile/src/ix-guest-runtime.nix;
        }
        ++ composition.guest {
          inherit nixRoot;
          repoRoot = ./.;
          inherit (config.ix.base) ixSecrets ixOpen;
          flox = flox.packages.${pkgs.stdenv.hostPlatform.system}.flox;
          blockvol = {};
        };

      options.ix.base = {
        ixSecrets = lib.mkOption {
          type = lib.types.package;
          description = ''
            The guest secrets client, installed as `ix-secrets` (ix builds it from crates/vm/guest/secrets-client).
            ix/base on ix gets it from ix; outside ix, pass any package that provides `bin/ix-secrets`.
          '';
        };
        ixOpen = lib.mkOption {
          type = lib.types.package;
          description = ''
            The guest `xdg-open` that forwards a URL to the client attached to the VM (ix builds it from
            crates/vm/guest/open). ix/base on ix gets it from ix; outside ix, pass any package whose `lib.getExe`
            names the binary; the image links it as `xdg-open`.
          '';
        };
      };

      # A system built from an external `nixpkgs.pkgs` takes neither setting (NixOS rejects `nixpkgs.config` beside
      # it); that caller applies overlays.default and allows claude-code itself (README.md).
      config.nixpkgs = lib.mkIf (!options.nixpkgs.pkgs.isDefined) {
        overlays = [btopOverlay];
        config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) ["claude-code"];
      };
    };
  };
}
