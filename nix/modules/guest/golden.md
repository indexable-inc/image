# golden.nix notes

Why lines in [golden.nix](golden.nix) look the way they do.

## context-1

A golden snapshot is cut after the guest finishes booting (ENG-12384), so every VM restored from the image resumes the same running units. Anything read before the freeze is baked in and shared. Per-machine state (secrets, identity, config) does not exist until the guest daemon writes it into `/run/ix` after a restore.

`ix-golden.target` is the capture point: units ordered before it are warm in the snapshot. `ix-restored.target` is the re-personalization point: units ordered after it see a real machine. The daemon raises it on every Configure-driven boot except the capture boot, after re-personalizing a restored template or after the SIGUSR1 handoff of a cold create or legacy restore (ENG-12588). Neither target does work. The assertions in this file, using ./golden-ordering.nix, refuse a guest whose units sit on the wrong side.

Only the pushed image (nix/packages/cas-image.nix) sets `ix.golden.captureMode`. `ix-closure-manifest golden-marker-check` fails the build if the manifest and rootfs disagree about the marker. Setting `captureMode` on an image whose manifest no host reads gives a guest that waits for a freeze nobody asks for.

## context-2

Every nameable unit is collected, not just services, because a target, socket or timer can also start a `/run/ix` reader in the capture boot. `config.systemd.units` is excluded: NixOS derives it from these families and keeps only `wantedBy`/`requiredBy`, with `Wants=` and `After=` already rendered into `text`.

## context-3

`systemd.mounts` and `.automounts` are lists whose unit names need systemd path escaping this module does not implement. Their forward edges are passed in unnamed so a mount that `Wants=` a `/run/ix` reader still fails the gate.

## context-4

No `example`: the old one named `ix-repersonalize`, a unit that never existed, and `nixos-option` output made it look like something to find.

## context-5

`/etc/ix/golden-boot-capture` is the image's capture-flow marker; only its presence matters. cas-image.nix copies it into the CAS manifest. The guest daemon does not read it (ENG-12588); it learns its mode from the capture-time Configure.

## context-6

`ix-golden.target` is wanted by `multi-user.target` and ordered after the same units. That is not a cycle, because `Wants=` carries no ordering.

## context-7

`ix-restored.target` is not wanted by the boot. The daemon starts it once secrets and identity are on disk. For a boot-init workload the daemon checks for `etc/systemd/system/ix-restored.target` in the toplevel (`handler::configure::unit_declaration_in`), and for other workloads in the image root's `etc/systemd/system` (the Ubuntu runner image in nix/base-images/ubuntu/runner too). Declaring the target opts the image in, and the host's Running waits for it. Renaming or dropping it silently turns the cold raise off.

A unit that reads per-machine state is `wantedBy` this target, ordered after it, pulled in by nothing else, and never `Wants=` it. `Wants=` pulls both ways: a capture-reachable unit would drag the target into the capture boot, read an empty `/run/ix`, and leave the target active inside the snapshot, where it satisfies the post-restore `StartUnit` so nothing re-runs (ENG-12579). ./golden-ordering.nix owns the target name the gate matches; renaming it here without there refuses every correct reader.
