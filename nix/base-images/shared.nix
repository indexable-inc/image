/**
What the ix base images share: `ix/base` (the NixOS guest, nix/lib/os/image.nix) and `ix/runner` (Ubuntu 24.04 for
GitHub Actions jobs, build/images/runner). Plain data and builtins only, so the pinned nix can evaluate it with no
nixpkgs (root//:runner-nix-conf-test renders the runner's nix.conf from it).

Each binary cache is listed with the keys its owner signs with, so an image can only trust a key by reading the cache
that needs it: a substituter without its key is silently useless (Nix rejects every narinfo and builds from source),
and a key without its cache only widens what a copied path may claim to be.

Returns `{ caches; images.<image>.caches; substituters; trustedPublicKeys; }`: two base images, one source of shared config.
*/
let
  keys = import ../../lib/fleet-cache-keys.nix;

  # Every base image reads these. cache.flox.dev alone holds flox's own builds (the flox CLI, its patched Nix,
  # catalog packages), and the guest ships the flox CLI (nix/packages/blockvol-base-artifact.nix). A runner job does
  # not get it from flox's flake nixConfig (accept-flake-config is off), and without it a cold store builds the flox
  # CLI's 1111 derivations (PR 4600).
  caches = [
    {
      url = "https://cache.nixos.org/";
      keys = [keys.cacheNixosOrg];
    }
    {
      url = "https://cache.flox.dev/";
      keys = [keys.floxCache];
    }
  ];

  # cache.ix.dev holds ix's own closures (everything ix publishes carries ix-workspace or ix-nix-cache-public-1),
  # which only the NixOS guest substitutes. It is not a pull-through of the caches above (a cache.nixos.org path
  # answers 404 there, 2026-10-20), so a runner listing it would pay one miss per path. Once it fronts them, it moves
  # into `caches` and this delta goes away.
  ixCache = {
    url = "https://cache.ix.dev/";
    keys = [keys.ncpsCurrent keys.ncpsLegacy keys.ixWorkspace keys.ixNixCachePublic];
  };
in {
  inherit caches;

  /**
  Dirty page cache bounds for a root whose metadata lives in segvol's 1 GiB data section (a zoned XFS root mounted with
  `rtdev=`). XFS charges a worst-case btree reservation to that section for every dirty file until writeback, so the
  default `vm.dirty_ratio` (20% of memory) lets a Nix substitution burst drive its free space to zero: 5 to 37 free
  blocks in 4 of 4 flox `nix develop` runs, against 58 to 75 MiB with these bounds and no slower (2026-10-21,
  ci-bench/data/delalloc-*.out). A streams root is one whole-device XFS and needs neither, so ./zoned-root-writeback.nix
  applies them only to a root with a realtime device.
  */
  zonedRootWriteback = {
    dirtyBackgroundBytes = 33554432;
    dirtyBytes = 134217728;
  };

  images = {
    guest.caches = [ixCache] ++ caches;
    runner.caches = caches;
  };

  /**
  The `substituters` value for a cache list, in list order (an equal Priority in nix-cache-info falls back to it).
  */
  substituters = map (cache: cache.url);

  /**
  The `trusted-public-keys` value for a cache list: every key its caches sign with, in list order.
  */
  trustedPublicKeys = list: builtins.concatLists (map (cache: cache.keys) list);
}
