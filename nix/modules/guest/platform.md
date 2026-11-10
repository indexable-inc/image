# platform.nix notes

Why lines in [platform.nix](platform.nix) look the way they do.

## context-1

`isContainer` makes nixpkgs' container-config.nix turn modprobe off, but ix guests have a kernel: the host boots linux-ix and injects its module tree at `/lib/modules/<kver>`. Without the re-enable, `/proc/sys/kernel/modprobe` points at a nonexistent `/sbin/modprobe`, every `=m` feature is dead, nftables.service fails with "Unable to initialize Netlink socket: Protocol not supported" and every switch exits 4 (ix#8408). The fix runs from activation, so `ix apply` heals a booted VM. kmod only takes a module prefix whose `<uname -r>` subdir exists, and ix toplevels ship no kernel-modules link, so resolution always lands on the running kernel's injected tree.

## context-2

`/tmp` is on the rootfs. A tmpfs `size=50%` is resolved once at mount time against `totalram_pages()` (mm/shmem.c, `shmem_parse_one`). An ix guest mounts `/tmp` with only the 3 GiB virtio-mem boot base present, so the cap freezes near 1.4 GiB on a 256 GiB VM (measured `size=1491832k`, 2026-07-29), and builds die ENOSPC (index#4332). Raising the fraction only trades ENOSPC for OOM. NixOS's `q /tmp 1777 root root 10d` tmpfiles rule ages out idle scratch. Files in `/tmp` ride along in snapshots. `mkDefault false` pins this against an upstream flip.

## context-3

Do not set `cleanOnBoot`. nixpkgs turns it into `D! /tmp`, so systemd-tmpfiles-setup deletes `/tmp` contents mid-boot while ix guests already accept exec (ENG-5440). Workloads saw SQLite "disk I/O error" and ENOENT (ix#7905, ix#7908).

## context-4

The kernel discards a tmpfs RAM fraction at mount time, so the image publishes the declared fractions for ix-vm-guest to re-resolve on a restored clone (ENG-12403). The path is duplicated as `MANIFEST_PATH` in crates/vm/guest/daemon/src/handler/configure/tmpfs_sizing.rs. A rename on one side shows up only as a debug line "image declares no RAM-derived tmpfs caps" in the guest journal.

## context-5

Interactive dev VMs run prebuilt binaries (npm CLIs, LSPs, toolchains) that expect an FHS dynamic linker.

## context-6

ix sets address, route and DNS before systemd services start. dhcpcd would wait forever for a lease and hold `network-online.target`.

## context-7

ix-vm-guest writes `/etc/resolv.conf` before the image starts. NixOS 26.05 enables resolvconf by default, and with no NixOS nameservers stage 2 overwrites the file with an empty one.

## context-8

Port-level policy lives in the guest's nftables firewall, in the container's own net namespace on the host's linux-ix kernel. ix itself provides only east-west group membership and north-south on/off.

## context-9

1 GiB journal cap so one log burst cannot fill a long-running VM's disk.

## context-10

userdbd is socket-activated, so it costs nothing idle. It makes `userdbctl` work and gives `DynamicUser=true` services a real user record.

## context-11

macOS Nix ships `nixbld*` users above uid 1000, which trips a systemd-userdb eval warning on the evaluating host. Those users never exist in the guest.

## context-12

The generator's `serial-getty@ttyS0` and `serial-getty@hvc0` are disabled. hvc0 is output only: the host never drains the receiveq (crates/vm/host/vmm/device/src/virtio/console.rs). ttyS0 carries printk into `vm_serial_logs`. Both units carry `BindsTo=dev-%i.device`, and no `.device` unit ever activates under `isContainer` because udev trigger and rules are dropped (ENG-11064). Each waited 90 s and failed, so every `ix apply` exited 4 after a clean switch (ENG-11063). `enable = false` writes a `/dev/null` symlink in `/etc/systemd/system`, which outranks the generator's copy. Masking the template does not work because the generator links straight to the store unit file.

## context-13

`ix-serial-getty` is the rescue shell for when the vsock ix-console path is starved. On 2026-08-17 a guest pegging its one core starved the ix-agent QUIC endpoint and left no way in. The unit has no `BindsTo=` or device ordering, and `ConditionPathExists=/dev/ttyS0` skips it cleanly on a guest without a serial port. `--autologin root` is required because the image ships `root:!:` in `/etc/shadow` and has no sshd or injected keys. Autologin adds no authority: `ix serial` and `ix shell` both need `vm:exec`, and the serial bridge refuses an attach without a signed Serial-audience JWT. The UART is teed into the `kernel` log stream, readable at `vm:read`, so rescue session input lands in `ix logs --stream kernel` and `vm_serial_logs`. Do not type secrets there. `--noclear` keeps clear-screen escapes out of that log.

## context-14

Without systemd-coredump a crashed service logs `signal=SEGV` and the core is lost. `MaxUse` stops a crash loop from filling the disk.

## context-15

`nix.optimise` stays off. Its timer is `OnCalendar=03:45`, so a golden captured before 03:45 UTC and restored after it fires `nix-store --optimise` seconds after restore. On a prod golden restore (2026-10-19) that held guest IO pressure at 55-64% for about 165 s, stretched a 4 KiB write+fsync to 4.7-15 s and failed the e2e gate (run 39199214649). It logged 120,911 "skipping suspicious writable file" lines and freed 189 KiB. With it stopped the worst interval was 312 ms over 283 writes. nix-gc on the same restore costs 451 ms CPU and 5 MB read, so it stays on, at 30 days. `allow-import-from-derivation` is set explicitly to pin repo policy against an upstream flip.

## context-16

The flake registry pin for `nixpkgs` lives in lib/image/default.nix because locking it needs the input's `narHash`. `NIX_PATH` makes `<nixpkgs>` resolve without a channel.

## context-17

No `blake3-hashes`: rendered rust units use sha256 (packages/nix-cargo-unit/src/render.rs), which stock nix accepts for reference-bearing fixed outputs.

## context-18

No `wasm-builtin`: `.ix` imports read the committed `<module>.ix.nix` renderings (packages/ix2nix/import-ix.nix).

## context-19

nixpkgs' nix-daemon module hardcodes `sandbox-fallback = false`, which makes a build fatal when the kernel lacks namespaces. ix guests run with `allowNamespaces = false` and the VM is the isolation boundary, so builds fall back to unsandboxed (index#2453). `mkForce` because the nixpkgs value is unconditional.

## context-20

Builds are usually the workload in an ix VM. At `idle` CPU and IO they lost to language servers and log streaming, and idle IO queued behind everything on the shared virtio-blk queue. A service VM that wants deprioritised builds sets `nix.daemonCPUSchedPolicy = "idle"` itself.

## context-21

`/bin/sh` and `/usr/bin/env` are baked into the image root, and a CAS-booted guest reaches `/bin` and `/usr` through symlinks into the read-only store. The stock recreate-and-rename snippets then fail every boot and every switch (ix#8307). They are blanked but stay defined so snippet dependencies resolve.

## context-22

An image root can bake `/bin`, `/sbin` and `/usr` as symlinks into the image's own closure. After one switch the guest's nix-gc collects that closure and all three dangle (seen on hyperion-game, 2026-07-29). Then `#!/bin/sh` scripts break, systemd-update-done fails on `Failed to stat /usr/`, logrotate fails at NAMESPACE, and a switch exits 4 (ENG-11063). Activation repoints only dangling links at `/run/current-system/sw`, a GC root. `/lib` is excluded because the host injects `/lib/modules/<kver>` into the rootfs.
