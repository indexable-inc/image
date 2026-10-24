# platform.nix policy rationale

Policy reasons for [platform.nix](platform.nix).

## context-1

`isContainer` makes nixpkgs' container-config.nix turn the modprobe
machinery off ("containers don't have a kernel"), but ix guests DO
have one: the host direct-kernel-boots linux-ix and injects that
kernel's full module tree at /lib/modules/<kver> in every rootfs.
Without this re-enable the guest has no module loader at all:
/proc/sys/kernel/modprobe keeps the kernel's compiled-in default
/sbin/modprobe (which does not exist here), so request_module()
fails and every =m kernel feature is dead, nftables.service dies
with "Unable to initialize Netlink socket: Protocol not supported"
on every boot and every switch exits 4 (ix#8408). Re-enabling the
upstream module (nixos/modules/system/boot/modprobe.nix) puts
pkgs.kmod on PATH and points the sysctl at its modprobe from an
activation snippet, which runs at boot AND during a switch, so the
fix reaches an already-booted VM through a plain `ix apply`.

Version skew is safe: nixpkgs kmod probes
/run/{booted,current}-system/kernel-modules first but only takes a
prefix whose <uname -r> subdir exists. ix toplevels never ship the
kernel-modules link (boot.kernel.enable = false under isContainer),
and a user toplevel carrying modules for some other kernel fails
the <uname -r> probe, so resolution always lands on the injected
/lib/modules tree of the RUNNING kernel.
astlog-ignore: no-mkforce container-config.nix sets this unconditionally for isContainer; ix#8408

## context-2

/tmp lives on the rootfs, like a normal machine. It used to be a
tmpfs on the theory that an ix VM has RAM to spare and an on-disk
/tmp grows without bound. Both halves of that theory are wrong
here.

`size=50%` is not half of the VM's memory. The kernel resolves the
percentage exactly once, when the filesystem is mounted, against
`totalram_pages()` (mm/shmem.c, the `*rest == '%'` branch of
`shmem_parse_one`), and stores the answer as a fixed block count.
Memory that shows up afterwards never raises it. An ix guest
mounts /tmp while only the unpluggable virtio-mem base is present
(`VIRTIO_MEM_BOOT_BASE_MIB`, 3 GiB), well before the host's
post-health-check resize, so the cap is taken against a ~3 GiB
total and then frozen for the life of the VM. Golden restore no
longer inherits that answer, `ix/tmpfs-sizing.json` below hands
the declared fraction to ix-vm-guest, which re-resolves it against
the restored machine's own memory (ENG-12403), but the boot-time
freeze against the 3 GiB base is still what a first boot gets.

Measured on two live hil guests (2026-07-29): /tmp mounted
`size=1491832k`, an absolute 1.42 GiB, not a percentage, while
the guest reported MemTotal 256 GiB. That is 0.55% of the VM's
RAM, and one of the two guests had that /tmp 100% full. /dev/shm
on the same guests resolved its own 50% against a slightly larger
total (1749884k), so the mount-time freeze is visible twice in one
mount table.

A build whose scratch exceeds the cap dies ENOSPC on a machine
advertising far more memory (index#4332), the exact failure
nixpkgs warns about in the `boot.tmp.useTmpfs` description.
Raising `tmpfsSize` does not fix it: the cap is bounded by the
3 GiB boot base either way, and spending a larger fraction of that
unpluggable floor only trades the ENOSPC for an OOM kill.

An on-disk /tmp is not unbounded either. NixOS ships systemd's own
`q /tmp 1777 root root 10d` tmpfiles rule and enables
systemd-tmpfiles-clean.timer, so idle scratch ages out on its own.
What it does cost is disk: temp files now occupy the rootfs and
ride along in snapshots until they are deleted. An image that
genuinely wants RAM-backed scratch sets `boot.tmp.useTmpfs = true`
for itself; mkDefault here restates the nixpkgs default so a
future upstream flip cannot silently reintroduce the cap.

## context-3

Do NOT set cleanOnBoot here. nixpkgs
nixos/modules/system/boot/tmp.nix turns it into an unconditional
`D! /tmp 1777 root root` tmpfiles rule, so
systemd-tmpfiles-setup.service deletes the CONTENTS of /tmp
partway through boot. ix guests accept exec/shell before systemd
activation settles (ENG-5440), so early workload writes to /tmp
were destroyed mid-run: SQLite "disk I/O error" + ENOENT on a
near-empty /tmp (ix#7905, ix#7908). Now that /tmp survives a
reboot the same rule would also destroy scratch written by an
earlier boot. The 10d age rule above reclaims the same space
without racing the workload.

## context-4

The mount-time RAM fractions this image declared, published for the guest
daemon's re-personalization step: the kernel throws the fraction away at
mount time, so a restored clone cannot recompute its own caps without
being told what they were meant to be. Path is duplicated in
`MANIFEST_PATH` in crates/vm/guest/daemon/src/handler/configure/
tmpfs_sizing.rs; a rename on either side shows up as "image declares no
RAM-derived tmpfs caps" at debug in the guest journal.

## context-5

Many ix VMs are SSH'd into and used as interactive dev machines, where
operators run unpatched prebuilt binaries (npm-installed CLIs, LSPs,
downloaded toolchains) that expect a standard FHS dynamic linker. Off
by default for the rare image that is genuinely a sealed appliance and
wants to drop the stub from its closure.

## context-6

ix provisions the guest address, route, and DNS before systemd reaches
normal service startup. Leaving NixOS DHCP enabled makes dhcpcd wait
for a lease that will never arrive, which keeps network-online.target
pending and blocks services such as minecraft.

## context-7

ix-vm-guest writes the runtime-provided nameservers to /etc/resolv.conf
before starting the image. NixOS 26.05 enables resolvconf by default;
with no NixOS-owned nameservers, stage 2 then replaces that file with an
empty one and breaks DNS in an otherwise connected VM.

## context-8

In-guest firewall is the NixOS nftables backend, enforcing each
module's `services.*.openFirewall` and `networking.firewall.allowed*`
declarations. ix VMs are `boot.isContainer = true` and share the
host's linux-ix kernel (CONFIG_NF_TABLES); nft rules run in this
container's own net namespace.

This is the primary mechanism for port-level policy. ix provides only
the coarse primitives (east-west group membership, north-south
on/off); per-port allowlists, L7, WAF, rate limiting, etc. live here
in the image or in a user-built gateway VM. The "primitives only"
rule is recorded in `ix/AGENTS.md` under "Architecture that must not
drift". The ix-side north-south primitive is tracked in index#41.

## context-9

Bound the journal so a long-running VM that catches one tcpdump-style
spam burst does not fill its disk with rotated journal files.
Override per image when an operator actually needs the historical
depth.

## context-10

Varlink multiplexer for JSON user/group records. On-demand activated,
so the cost when nothing queries it is negligible. Having it on means
operator-side `userdbctl user/group` works out of the box, services
that adopt `DynamicUser=true` get proper cgroup accounting through a
synthesized record, and the eventual NFTSet=/cgroup-id integration
over the nftables backend already enabled here can hook into real
user/group identities without another platform-wide flip.

## context-11

macOS Nix installs (and other multi-user setups) ship `nixbld*`
build users above 1000, which trips the systemd-userdb "regular
users have system-range UIDs" warning at eval time. The build
users do not exist inside ix VMs at all. `boot.isContainer =
true` means the guest has its own user namespace. so the
warning is noise from the host nixpkgs evaluator rather than a
runtime concern. Silencing here keeps `nix run .#health-checks`
and other repo evals scannable.

## context-12

No serial login prompt. systemd-getty-generator instantiates a serial
getty for every console in /sys/class/tty/console/active plus the first
virtio console it finds, so an ix guest gets serial-getty@ttyS0 (the
host's DEFAULT_CMDLINE sets `console=ttyS0`,
crates/vm/host/vmm/kvm/src/cmdline.rs) and serial-getty@hvc0 (the
generator probes /sys/class/tty/hvc0, which the virtio-console driver
registers whether or not a host end is attached). Neither device can
carry a login session:

  * hvc0 is output only. The host drains the transmitq into a per-VM log
    file and deliberately never drains the receiveq, so no keystroke can
    reach a getty there (crates/vm/host/vmm/device/src/virtio/console.rs).
  * ttyS0 carries kernel printk, is captured to a log file and ingested
    into ClickHouse `vm_serial_logs`, and `ix serial` claims it as a
    single-holder attach. A getty would only write its login banner into
    that log.

Interactive access is ix-console over vsock (port 5001, claimed above),
which allocates its own PTY and wants no getty at all.

Left in place they do not idle, they fail every switch: serial-getty@
carries `BindsTo=dev-%i.device`, and no .device unit EVER activates in an
ix guest, because `boot.isContainer = true` drops both
systemd-udev-trigger.service and every udev rule, so nothing is ever
tagged `systemd` (ENG-11064 has the measurements; dev-vda.device, the
root disk, reads `tentative` for the same reason). Each job waits out its
90s JobTimeoutSec and fails, the getty is dependency-failed, and
switch-to-configuration exits 4, so EVERY `ix apply` of a guest reported
failure while having actually switched cleanly (ENG-11063). Same shape as
the modprobe/nftables case in ix#8408.

`enable = false` renders each instance as a /dev/null symlink in
/etc/systemd/system, which outranks the generator's /run/systemd/generator
copy in systemd's unit load path, so the generator stays free to keep
inventing them. Masking the `serial-getty@.service` template instead
would not work: the generator symlinks straight at the unit file in the
systemd store path, so the instances would still load.

## context-13

The rescue prompt the masked instances above cannot be. Masking is
still correct, the generator's instances are unfixable, because the
`BindsTo=dev-%i.device` is baked into the systemd store path and no
.device unit ever activates under `boot.isContainer`, but masking on
its own left ix guests with exactly one interactive path: ix-console
over vsock. That path runs inside the guest as a process scheduled
alongside the workload, so the failure that most needs a rescue shell
is the failure that takes the rescue shell with it. On the 2026-08-17
dev fleet a guest that pegged its single entitled core starved the
ix-agent QUIC endpoint until it stopped answering, and there was no
second way in: the VM was wedged with a live kernel, a live serial
console carrying printk, and nothing on the far end of it to log into.

This unit is that second way in. It is deliberately NOT an instance of
`serial-getty@`: it carries no `BindsTo=`, no `After=dev-ttyS0.device`,
and no `Requires=` on anything a container-mode guest cannot activate,
so it starts on the same boot every generator instance would have hung
on. `ConditionPathExists` is the whole device check, devtmpfs has
/dev/ttyS0 long before multi-user.target, and a guest booted without a
serial port simply skips the unit as a satisfied no-op rather than
failing it.

`--autologin root`, deliberately, because the alternative is a prompt
nobody can answer. This image sets no root credential anywhere:
`users.defaultUserShell` above is the only `users.*` fact it states, so
nixpkgs' update-users-groups.pl falls through to `my $hashedPassword =
"!"` and the guest ships `root:!:` in /etc/shadow, which pam_unix can
never authenticate against. There is no sshd in the image and no
authorized_keys injection on the ix side either. A bare agetty here
would answer every rescue attempt with "Login incorrect", a rescue
path that cannot be entered is not one. The alternative, baking a
password hash into a shared base image, would put one guessable
long-lived secret in front of every guest in the fleet; a per-VM
injected credential is real control-plane machinery (mint, store,
deliver, rotate) and is not what this unit is.

Autologin grants no authority the caller lacks. `ix serial` and
`ix shell` mint their connect tokens through the same op-level gate,
`vm:exec`, behind the same owner-or-platform-admin check; ix's
per-audience escalation table lifts only the `Switch` audience, and the
one non-owner mint path is hardcoded to port-forward. Every principal
who can reach this getty already has root in the guest via `ix shell`,
and the serial bridge refuses any attach without a signed
Serial-audience JWT.

Known cost, accepted: the emulated UART is teed into the capture file
backing the `kernel` log stream, and that stream reads at `vm:read` --
weaker than the `vm:exec` an attach needs. A rescue session's prompt and
echoed commands therefore land in `ix logs --stream kernel` and
ClickHouse `vm_serial_logs` alongside kernel printk. The tee is a
property of using serial at all rather than of autologin, but it does
mean this console is not the place to type secrets. `--noclear` keeps a
respawn from also emitting a screen-clear escape sequence into that log.

## context-14

Capture native crashes (JVM segfault, Rust panics in extern, anything
that takes SIGSEGV/SIGABRT) into /var/lib/systemd/coredump where
`coredumpctl list/info/gdb` can find them. Without this, a crashed
service shows `signal=SEGV` in the journal and the dump goes to
/dev/null. MaxUse caps a crash-looping service rather than saving
disk. disk autoscales to ~1 PiB, the cap is just defence in depth.

## context-15

Modern Nix configuration for any in-VM nix invocation.

experimental-features: nix CLI, flakes, the `|>` pipe operator,
fetchClosure, content-addressed derivations, dynamic derivations,
and git tree hashing. List-typed, so per-image additions concatenate
rather than override.

allow-import-from-derivation: IFD is allowed by upstream default;
setting it explicitly pins repo policy ("IFD is allowed when it
removes a fake Nix layer", AGENTS.md) against a future upstream flip.

gc: long-lived dev VMs accumulate roots from `nix run` /
`nix shell` and never get a /nix/store sweep otherwise. 30 days
keeps recent results for repeat invocations and bounds disk growth.

optimise stays off. Its timer is `OnCalendar=03:45`, and a golden
captured before 03:45 UTC and restored after it fires
`nix-store --optimise` within seconds of the restore, because the
restored systemd sees the clock jump past the elapse. That run reads
every file of the lazily paged store and, on ix/base, logs one
"skipping suspicious writable file" line per store file (120,911
lines, 235 MB of journald writes, 189 KiB freed). On a prod golden
restore (2026-10-19) it held guest IO pressure at 55-64% from 89 s
to 255 s uptime and stretched a 4 KiB write+fsync to 4.7-15 s, which
failed the prod e2e gate's arm step (run 39199214649). With only
nix-optimise stopped, the same restore measured a 312 ms worst
interval over 283 writes. nix-gc runs on the same restore and is
cheap (451 ms CPU, 5 MB read), so it stays.

## context-16

The system flake registry pin for `nixpkgs` lives in
lib/image/default.nix (an inline module next to `nixpkgs.pkgs`),
because locking it needs the flake input's `narHash`, which only
that scope has.

NIX_PATH so legacy nix-shell / <nixpkgs> imports resolve without a
channel subscription or network fetch.

## context-17

No `blake3-hashes`: rust units address their output with sha256
(packages/nix-cargo-unit/src/render.rs, 2026-09-20), the one
algorithm stock nix takes for a reference-bearing fixed output, so
an in-VM `nix build` of a rendered unit needs no extra feature.

## context-18

No `wasm-builtin` (dropped 2026-09-20): `.ix` imports read the
committed `<module>.ix.nix` renderings (packages/ix2nix/import-ix.nix),
so an in-VM `nix build` / `nix eval` of a `.ix` module needs no
evaluator feature at all.

## context-19

nixpkgs' nix-daemon module bakes `sandbox-fallback = false` as a
"legacy configuration conversion" (nixos/modules/services/system/
nix-daemon.nix), which turns a build FATAL the moment the kernel
lacks the namespaces sandboxing needs. ix guests deliberately run
without user namespaces (hardening sets `allowNamespaces = false`)
and the VM is itself the isolation boundary, so a build that cannot
be sandboxed should degrade to an unsandboxed build with a warning,
not kill `ix apply`. Restore Nix's own upstream default of `true`.
mkForce because the nixpkgs assignment is unconditional, not a
default. See index#2453.
astlog-ignore: no-mkforce nixpkgs sets this unconditionally; #2453 owns the fix.

## context-20

The nix-daemon runs builds at normal CPU and IO priority (`other`,
`best-effort`), the same as every other process in the guest. It ran
at `idle` for both, to keep ad-hoc nix work an operator ran over SSH
from starving a service workload. But in most ix VMs the builds are
the workload (CI jobs, `nix build` in a dev VM), and `idle` let any
background task (a language server, a file indexer, the job's own
log streaming) take the CPU and disk from them; idle IO also waits
behind every other queued request on the shared virtio-blk queue.
A service VM that wants its builds deprioritised sets
`nix.daemonCPUSchedPolicy = "idle"` (or `batch`) itself.

## context-21

/bin/sh and /usr/bin/env are baked into every image root at build time
(oci-layer.nix systemRoot here; the CAS systemRoot on the ix side), and
the CAS-booted guest reaches /bin and /usr through symlinks into the
read-only store, so the stock recreate-and-rename these snippets run
can never succeed there: both fail on every boot and would fail the
Activating phase of a switch (ix#8307). Blank them; the attrs stay
defined so snippet dependency resolution is unaffected. mkForce because
nixpkgs assigns both snippets unconditionally, not as defaults.

## context-22

Heal the FHS compat entries when they dangle. An image root can bake
/bin, /sbin and /usr as absolute symlinks into the closure that built
the IMAGE rather than into anything stable. Nothing repoints them on a
switch, and the guest's own nix-gc then collects that closure, so on
any VM that has switched once all three dangle at the same time.
Measured on hyperion-game (2026-07-29), which had switched away from
its image closure and GC'd it:

  /usr -> /nix/store/fna5ylak...-nixos-system-nixos-26.11.../sw  [DANGLING]

The consequences are not subtle. /bin/sh stops existing, so every
`#!/bin/sh` script in the guest is broken; systemd-update-done dies on
`Failed to stat /usr/`; and logrotate dies at step NAMESPACE building
its mount namespace. The last two exit a switch 4, which an apply
reports as a failed target (ENG-11063).

/run/current-system/sw is the stable target: activation repoints it on
every switch and it is itself a GC root, so it cannot go the same way.
Only a symlink that fails to resolve is touched, so a root laid out
with real /bin and /usr directories (oci-layer.nix since ix#8307) is
left exactly as the image built it. /lib is deliberately not in the
list: the host injects the running kernel's module tree at
/lib/modules/<kver> in the rootfs, and a symlink into the system
closure would not carry it (ix toplevels ship no kernel-modules link).

Activation runs at boot AND during a switch, so an already-booted VM
heals through a plain `ix apply` with no image rebuild and no recreate.
