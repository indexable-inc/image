/**
The public keys the fleet trusts on a narinfo signature. Single source of
truth for `nix.settings.trusted-public-keys`.

Surfaces as `ix.lib.fleetCacheKeys`. Consumed by:
  - `nix/modules/base/nix-settings.nix`: the trusted set on every host.
  - `scripts/ci/probe-cache-plane.sh`: asserts the key the ncps cache
    actually signs with is one of these, so a regenerated ncps keypair
    reddens CI instead of turning every fleet substitution into a rebuild.
  - `nix/base-images/shared.nix`: pairs each base-image cache with its keys;
    the guest and runner images trust exactly the keys of the caches they read.

`ncpsCurrent` is the one that matters day to day: ncps re-signs everything it
serves, and paths whose only signature is ncps's (anything published without
an upstream signature) verify on that key alone.

The guest image mirror (github.com/indexable-inc/image) publishes this file, so its comments name no host,
bucket or secret; where each secret half lives is in lib/nix-cache-endpoint.nix.
*/
let
  # ncps narinfo signing key. The label is the hostname ncps generated the
  # keypair on, and ncps generates a fresh keypair whenever it starts against
  # an empty `/var/lib/ix/ncps`. Moving the cache plane (ix#8019) did exactly
  # that, so the label changed from the one below (ENG-10618).
  ncpsCurrent = "hil-stor-2:UYyDQcJ/iepiePK/ptHRqR2t98okIpsfOVqE0Pm5CwY=";

  # The pre-ix#8019 ncps keypair, retained only so a store path signed by the
  # old cache-plane owner and copied between nodes still verifies. Nothing
  # signs with it now; drop it once no such path survives.
  ncpsLegacy = "hil-compute-1:eu2JX3qkNaxdO0/ane+bTmOIKOtR5P/quLlTHBqqIpM=";

  # atticd signs the `ix-public` cache server-side. Everything ix itself
  # publishes, and every FOD the workspace fetches, carries this and only
  # this upstream signature, so a guest that does not trust it rebuilds all of
  # ix from source (ENG-10618).
  ixWorkspace = "ix-workspace:JuAaeOPfR3GL3nUICpEz/88/+S3BzGF3L6bPYFy0GwI=";

  # Root-only CI publishers signed the retired internal cache's narinfos with
  # this key. Paths mirrored from there into the S3 cache keep this signature
  # and were re-signed with `ixNixCache2`. Drop it from `all` once nothing
  # reads the OVH cache (lib/nix-cache-endpoint.nix `legacy.retireBy`); the
  # nix-edge pin's `signatureKey` must move to -2 first.
  ixNixCache = "ix-nix-cache-1:E2jhzdBkWzTcF6139ogjZYzmdvGkJh79tS8PgrciyxU=";

  # Signs everything published to the S3 cache (lib/nix-cache-endpoint.nix),
  # minted 2026-10-09.
  ixNixCache2 = "ix-nix-cache-2:oZoBT7muHbjvJidWyjk5//kHzVmfm1UbvUqMPn9nil4=";

  # Signs the PUBLIC cache, https://cache.ix.dev: content-addressed outputs and signed build-trace entries of
  # redistributable closures, what guests substitute from (docs/design/nix-ca.md). Minted 2026-10-15.
  ixNixCachePublic = "ix-nix-cache-public-1:kLfLbVu3idGD86gEfIs7/DRvdxte8HcPHqdInRm9Lk0=";
  cacheNixosOrg = "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=";

  # flox's binary cache (`cache.flox.dev`, the flox CLI closure + their daily
  # nixpkgs catalog builds). ncps fronts it as an upstream
  # (`nix/modules/services/host/cache-surface/module.nix`) because the guest
  # base image ships flox; ncps re-signs what it serves with `ncpsCurrent`, so
  # verification would hold on that alone. This key is here so a flox-signed
  # path copied between nodes verifies without the ncps hop, same reason
  # `indexCachix` stays. The guest-side copy of this value lives in index
  # `lib/cache.nix` (`flox` attr); keep the two in sync. Key source:
  # github.com/flox/flox flake.nix `nixConfig.extra-trusted-public-keys`.
  # flox's docs also list `floxhub-1`, which signs what any FloxHub user publishes (flox/docs customer/signing-keys.mdx).
  # Trusting it would let a stranger's upload stand in for an input-addressed path we build, so nothing here trusts it.
  floxCache = "flox-cache-public-1:7F4OyH7ZCnFhcze3fJdfyXYLQw/aV7GEed86nQ7IsOs=";

  # Retained (cachix is no longer a substituter) only so any pre-existing
  # cachix-signed store path stays verifiable when copied between nodes.
  indexCachix = "indexable-inc.cachix.org-1:HQ5mjdOyhgNjLVhjv0qgVMJ5YiO1zEEVMAtF9mTcpiI=";

  /**
  Every key above, in the order `trusted-public-keys` should list them.
  */
  allKeys = [
    ncpsCurrent
    ncpsLegacy
    ixWorkspace
    ixNixCache
    ixNixCache2
    ixNixCachePublic
    cacheNixosOrg
    indexCachix
    floxCache
  ];
in {
  inherit
    ncpsCurrent
    ncpsLegacy
    ixWorkspace
    ixNixCache
    ixNixCache2
    ixNixCachePublic
    cacheNixosOrg
    indexCachix
    floxCache
    ;

  all = allKeys;
}
