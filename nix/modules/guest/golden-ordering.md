# golden-ordering.nix policy rationale

Policy reasons for [golden-ordering.nix](golden-ordering.nix).

## context-1

The post-restore ordering predicate: which units in a boot-then-capture guest
may read this machine's state under `/run/ix`, and the message raised for each
one that may not.

Pure, and separate from `./golden.nix`, so the answer can be tested without
evaluating a guest system. `nix/checks/lib-unit/golden-ordering.nix` is the
red/green pair, and it carries one fixture per broken shape below.

WHAT THIS DEFENDS AGAINST. A unit that reads `/run/ix` during the capture boot
does not fail. It succeeds against an empty directory, and the
succeeded-with-nothing result is what gets frozen. Every machine restored from
the image then resumes a process that was configured from no machine's secrets,
identically, with no error on any host and nothing in any journal to find. The
blast radius is the image, not the VM.

WHY AN `After=` EDGE IS NOT THE TEST (ENG-12579). `After=` is ordering and
nothing else: it does not say whether the unit runs during the capture boot, and
until ENG-12579 an `After=` edge was the entire pass condition, so both shapes
that carry one were certified, including the shape the failure message itself
used to prescribe.

  after = [ "ix-restored.target" ]; wants = [ "ix-restored.target" ];
  wantedBy = [ "multi-user.target" ];

    `Wants=` pulls in BOTH directions. The capture boot reaches the unit through
    `multi-user.target`, the unit's own `Wants=` drags `ix-restored.target` into
    that same transaction, the target has no work of its own so it activates at
    once, and the unit then starts "after" it against an empty `/run/ix`. It
    gets worse from there: the target is now active INSIDE the snapshot, so the
    guest daemon's post-restore `StartUnit` is satisfied the moment it is asked,
    `RestoreComplete` latches, the host accepts the boot, and the unit never
    re-runs against the real per-machine secrets on any VM.

  after = [ "ix-restored.target" ]; wantedBy = [ "multi-user.target" ];

    `ix-restored.target` is not in the capture-boot transaction at all, so the
    `After=` edge orders the unit against nothing that will run and it starts
    immediately during the capture boot.

The shape that works is the one where the capture boot cannot reach the unit at
all: pulled in by `ix-restored.target`, pulled in by nothing else, ordered after
it, and named by no `Wants=` anywhere. That is what `findings` tests.

WHAT IT CANNOT SEE, and this is most of the surface. Only `serviceConfig` is
legible at eval time. A unit whose payload opens `/run/ix/secrets` from inside
its own code, an application reading a path it resolves at runtime, a config
loader, anything one exec away from the unit file, is invisible here and
always will be. `systemd.services.<name>.script` is the common case of exactly
that: NixOS compiles the body into a store path and the `ExecStart=` this reads
is that path, so a script opening `/run/ix/secrets` reads here as a store path
with no `/run/ix` in it. Those units need the ordering written by hand and
nothing mechanical will remind anyone. Also invisible: ordering or activation
that arrives through a drop-in outside this evaluation, a hand-written
`systemd.units."<name>"` whose dependencies live in its rendered `text` rather
than in typed options, `systemd.user.*` units (a different manager), and dbus
activation. A timer, socket or path unit that activates an offending service is
half-visible: the activator is not an edge this can read, so a service reachable
only that way has no puller here and is refused for that reason, the ordering
has to go on the service either way.

WHICH DIRECTION A WRONG ANSWER FAILS IN. `postRestoreOnly` is grown outward from
`ix-restored.target` rather than pruned inward from the boot, because the capture
boot's own graph belongs to systemd and is not in this evaluation: `multi-user.target`
reaches most of a system through unit files no Nix expression here can read. So
a unit is capture-reachable unless this predicate can prove otherwise, and every
gap above therefore reads as unsafe rather than as safe.

## context-2

EnvironmentFile= and LoadCredential= are read by systemd itself before the
payload's first instruction, so ordering is the only thing that can put
content behind them. An ExecStart* naming one of the paths is the same
story one layer out. LoadCredentialEncrypted= is the same directive with a
decryption step and is included for that reason, not because anything uses
it today.

## context-3

Both spellings of one edge. The lowercase name is the NixOS option;
`unitConfig.<Directive>` is the same directive written by hand, and systemd
accepts several units in one space-separated value. Reading only the first
would let the gate be silenced by writing the dependency the other way,
which is the opposite of what it is for, and in a real NixOS evaluation
the second spelling is not even optional, because the systemd module mirrors
`wants`/`requires`/`after` into `unitConfig` itself (nixpkgs
nixos/lib/systemd-lib.nix). Hence the `lib.unique` on the puller lists: the
same edge legitimately arrives twice.

## context-4

The reverse spelling: NixOS renders these into `<other>.wants/<this>`
symlinks, so the unit doing the pulling is the one NAMED here. There is no
`unitConfig` counterpart on purpose, `WantedBy=` is an [Install] directive
and `unitConfig` writes [Unit], where systemd ignores it, so reading it here
would credit a unit with an activation path it does not have.

## context-5

Every unit whose relationship to `/run/ix` is unsafe, as
  `[ { unit; message; } ]`, empty when the guest is clean.

  units          every nameable unit in the evaluation, keyed by FULL unit name
                 (`"foo.service"`). Not services-only: whether a reader can be
                 started by the capture boot is a question about every unit that
                 could pull it in.
  anonymousPulls units pulled in by a unit this evaluation cannot name. The
                 `systemd.mounts` / `.automounts` families are lists whose unit
                 names come from path escaping no caller here implements, so
                 their forward edges arrive this way rather than being dropped.
  stateWriters   `ix.golden.stateWriters`: service names WITHOUT the `.service`
                 suffix, exempt because they write the state rather than read it.

## context-6

A unit is post-restore-only when the only things that can pull it in are
`ix-restored.target` or other post-restore-only units. Grown outward from
the target for the reason in this file's header: proof of safety, not
absence of a known-bad name.
