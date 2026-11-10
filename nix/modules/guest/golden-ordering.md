# golden-ordering.nix notes

Why lines in [golden-ordering.nix](golden-ordering.nix) look the way they do.

## context-1

The predicate for which units in a boot-then-capture guest may read `/run/ix`. It is pure so build/nix-lib/cases/golden-ordering.nix can test it without evaluating a guest; that file has one fixture per broken shape.

A unit that reads `/run/ix` during the capture boot does not fail. It succeeds against an empty directory, the snapshot freezes that result, and every restored VM runs unconfigured with no error anywhere.

An `After=ix-restored.target` edge is not the test (ENG-12579). With `wants = ["ix-restored.target"]` and `wantedBy = ["multi-user.target"]`, the capture boot pulls in the target, it activates at once, the unit reads an empty `/run/ix`, and the target stays active in the snapshot so the post-restore `StartUnit` is a no-op. Without the `wants`, the target is not in the capture transaction and the unit just starts during capture. The safe shape is pulled in only by `ix-restored.target`, ordered after it and named by no `Wants=`.

Only `serviceConfig` is visible at eval time. A unit whose code opens `/run/ix/secrets` at runtime is invisible, and so is `systemd.services.<name>.script`, which compiles to a store path in `ExecStart=`. Drop-ins from outside this evaluation, hand-written `systemd.units."<name>"` text, `systemd.user.*` units and dbus activation are invisible too. A service started only by a timer, socket or path unit has no visible puller and is refused. Every gap reads as unsafe because reachability is proven outward from the target, not pruned inward from the boot.

## context-2

systemd reads `EnvironmentFile=` and `LoadCredential=` before the payload starts, so only ordering can put content behind them. `LoadCredentialEncrypted=` is the same directive plus decryption.

## context-3

Both spellings of an edge are read: the NixOS option and `unitConfig.<Directive>`, which may hold several space-separated units. The systemd module mirrors `wants`/`requires`/`after` into `unitConfig` itself (nixpkgs nixos/lib/systemd-lib.nix), so the same edge arrives twice; hence `lib.unique`.

## context-4

`wantedBy`/`requiredBy` become `<other>.wants/<this>` symlinks, so the puller is the unit named. `unitConfig` is not read here because `WantedBy=` is an [Install] directive and systemd ignores it in [Unit].

## context-5

Returns `[ { unit; message; } ]`, empty when clean. `units` is every nameable unit keyed by full name (`"foo.service"`). `anonymousPulls` are units pulled in by mounts and automounts, whose names need path escaping. `stateWriters` (`ix.golden.stateWriters`) are service names without `.service`, exempt because they write the state.

## context-6

A unit is post-restore-only when only `ix-restored.target` or other post-restore-only units can pull it in.
