/**
The ix/base guest settings that are not a module of their own: the image's nixpkgs pin and flake
registry, the fetcher-cache seed, the zoned-root writeback bound, the build toolchains, the binary
caches and the users-ready publication.

Arguments: `nixpkgs`, the locked nixpkgs flake input the image pins (its `rev`, `narHash`,
`lastModified` and `outPath`), and `nixRoot`, the `nix/` directory. Returns a NixOS module. It
sets no `nix.package`: ix sets its own Nix build beside it (./image.nix).
*/
{
  nixpkgs,
  nixRoot,
}: {
  config,
  lib,
  pkgs,
  ...
}: let
  # The image's nixpkgs as a locked `github:` input: what a flake.lock written in a VM
  # records, so the lock works anywhere (a `path:` pin into this store would not).
  nixpkgsPin = {
    type = "github";
    owner = "NixOS";
    repo = "nixpkgs";
    inherit (nixpkgs) rev narHash lastModified;
  };
  fetcherSeed = import ./nixpkgs-fetcher-seed.nix {inherit pkgs nixpkgs;};
  # Flake inputs resolve indirect ids through the global registry only (Determinate Nix),
  # so a flake using plain `nixpkgs` locks to whatever that names. This is the upstream
  # registry (./flake-registry.json, NixOS/flake-registry 46ea0f17cf67, vendored so the
  # image builds offline) with its unqualified `nixpkgs` entries pointed at the pin;
  # `nixpkgs/<branch>` and every other id resolve as upstream.
  upstreamRegistry = builtins.fromJSON (builtins.readFile ./flake-registry.json);
  globalRegistry = pkgs.writeText "flake-registry.json" (builtins.toJSON (upstreamRegistry
    // {
      flakes = map (entry:
        if
          entry.from
          == {
            id = "nixpkgs";
            type = "indirect";
          }
        then entry // {to = nixpkgsPin;}
        else entry)
      upstreamRegistry.flakes;
    }));
  seedUsers = lib.filterAttrs (_: user: user.isNormalUser) config.users.users;
  sharedImageConfig = import (nixRoot + "/base-images/shared.nix");
  guestCaches = sharedImageConfig.images.guest.caches;
in {
  nix.registry.nixpkgs.to = nixpkgsPin;
  nix.settings.flake-registry = "${globalRegistry}";
  # Resolving that pin is local: the image's nixpkgs is already in Nix's fetcher cache for
  # root and every normal user (nixpkgs-fetcher-seed.nix), so the first `nix ... nixpkgs#x`
  # neither downloads nor unpacks it (14-18 s without; 0.18 s with). Every boot, idempotent,
  # before multi-user.target and so before a golden capture.
  systemd.services.ix-nix-fetcher-seed = {
    description = "Seed Nix's fetcher cache with the image's nixpkgs";
    wantedBy = ["multi-user.target"];
    path = [pkgs.coreutils pkgs.sqlite];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script =
      fetcherSeed.script
      + ''
        seed_home /root root root
      ''
      + lib.concatStrings (lib.mapAttrsToList (name: user: ''
          seed_home ${lib.escapeShellArg user.home} ${lib.escapeShellArg name} ${lib.escapeShellArg user.group}
        '')
        seedUsers);
  };
  # Bounds dirty pages when the root is segvol's zoned XFS, whose 1 GiB metadata section a writeback burst
  # can exhaust (nix/base-images/shared.nix zonedRootWriteback). Before sysinit, so no workload writes first.
  systemd.services.ix-zoned-root-writeback = {
    description = "Bound dirty pages on a zoned segvol root";
    wantedBy = ["sysinit.target"];
    before = ["sysinit.target"];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = import (nixRoot + "/base-images/zoned-root-writeback.nix") {proc = "/proc";};
  };
  # A first build starts building, not downloading compilers: the common toolchains are on the system
  # path, and the stdenv's closure is in the store (registered), so `nix build` of an ordinary derivation
  # fetches only what it builds from. Before this a fresh VM spent 14 s fetching cargo, rustc and gcc
  # before the first compile (Graviton5, 2026-10-17).
  # util-linux is part of the job PATH as well. GitHub-hosted Linux
  # images expose tools such as `rev` and `column`; ix runner jobs use
  # the guest system profile instead, and missing them turns a valid
  # Flox test into an environment failure.
  environment.systemPackages = with pkgs; [rustc cargo clippy rustfmt gcc binutils gnumake pkg-config python3 util-linux];
  assertions = [
    {
      assertion = lib.elem pkgs.util-linux config.environment.systemPackages;
      message = "the guest image must expose util-linux to job processes";
    }
  ];
  system.extraDependencies = [nixpkgs.outPath pkgs.stdenv];
  # Legacy `<nixpkgs>` (nix-instantiate, nix-shell -p) reads that same source directly; a
  # `flake:nixpkgs` NIX_PATH goes through the flake machinery and took 3.8 s vs 1.75 s for
  # firefox on metal (2026-10-16).
  nix.nixPath = ["nixpkgs=${nixpkgs.outPath}"];
  # NixOS exports nixPath only as the NIX_PATH session variable, which non-login processes (`ix exec`,
  # agents, CI steps) never get, and leaves nix.conf's nix-path empty, so `<nixpkgs>` failed there. Nix
  # reads nix.conf in every process. build/checks/base-nix-path-artifact.nix checks it without NIX_PATH.
  nix.settings.nix-path = config.nix.nixPath;
  # The host's memory policy owns OOM (ix_oom_request, the autoscaler); oomd only woke every
  # idle VM about 4.5 times a second to watch pressure nothing acts on.
  systemd.oomd.enable = false;
  # These settings belong in the guest system, since activation writes
  # /etc/nix from this configuration and would replace an OCI overlay.
  # The caches every base image shares, plus the guest's own (nix/base-images/shared.nix).
  # mkForce: NixOS appends cache.nixos.org on its own, which listed it twice.
  nix.settings.substituters = lib.mkForce (sharedImageConfig.substituters guestCaches);
  nix.settings.trusted-public-keys = sharedImageConfig.trustedPublicKeys guestCaches;
  # The base image publishes /run/ix/users-ready like every template
  # (ix-machine-profile.nix); the index base profile set this until
  # eeeadbaf29 deleted it. root//:users-publication-contract-test reads both.
  ix.usersReady.enable = true;
}
