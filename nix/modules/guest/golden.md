# golden.nix policy rationale

Policy reasons for [golden.nix](golden.nix).

## context-1

The two points a boot-then-capture guest is cut at.

The old shape captured the golden snapshot BEFORE systemd started, so a
restored VM paid for the whole of boot after the resume. Boot-then-capture
moves the cut to the other side of it: the guest boots all the way, the host
freezes the running machine, and a restore resumes into a system whose units
are already up. Design: ENG-12384.

That trade buys warm boot and costs the guest a distinction it never had to
make before. A snapshot is taken once and resumed by EVERY machine created
from this image, so any state the guest reads BEFORE the freeze is state that
gets baked in and shared. Per-machine state, this VM's secrets, this VM's
identity, this VM's config, does not exist yet at capture time and cannot,
because no machine has been created. It arrives only after a restore, written
into /run/ix by the guest daemon during re-personalization.

Two targets name the two moments, so a unit can say which side of the cut it
belongs on instead of every author re-deriving the argument above:

  ix-golden.target    the capture point. Everything ordered Before= it is
                      warm in the snapshot.
  ix-restored.target  the re-personalization point. Everything ordered
                      After= it sees a machine that exists. The guest
                      daemon raises it on every Configure-driven boot
                      except the capture boot: after re-personalizing a
                      restored template, and after the SIGUSR1 handoff of
                      a cold create or a legacy restore that boots this
                      system through boot-init (ENG-12588,
                      https://linear.app/indexable/issue/ENG-12588).

Neither target does any work. They are ordering vocabulary, and the value is
that the vocabulary is checkable: the assertions at the bottom of this file
refuse to build a guest whose units are on the wrong side of the cut.
./golden-ordering.nix is the predicate they raise, and carries the argument
for why "the unit declares After=ix-restored.target" is not that predicate
(ENG-12579: it certified both shapes that leak, one of which the failure
message itself used to prescribe).

WHERE THIS MODULE IS IMPORTED, AND WHICH HALF EACH IMPORTER GETS.

Three ix evaluations layer it in, and they want different things out of it
(ENG-12402):

  packages/cas-image.nix           the PUSHED image. Targets, gate, AND
                                   `ix.golden.captureMode`. The marker lands
                                   in this image's /etc, cas-image.nix mirrors
                                   it into the CAS manifest. No host code
                                   reads it to pick a capture flow now.
                                   `ix-closure-manifest golden-marker-check`
                                   fails the image build if the manifest and
                                   the rootfs disagree about it.
  packages/blockvol-base-artifact.nix  the node's BASE BLOCK IMAGE, which the
                                   capture VM boots before the pushed image is
                                   applied. Targets and gate only, never the
                                   marker: nothing reads a manifest of this
                                   image, so a marker here declares a flow to
                                   nobody (ENG-12402). It is inert rather than
                                   dangerous since ENG-12588, the guest
                                   daemon no longer reads the file at all --
                                   but a declaration no reader consumes is
                                   still a lie about what the image is.
  modules/services/host/regional-status/index-integration.nix
                                   the regional status fleet's nodes, whose
                                   own CAS images are pushed by the same
                                   machinery. Targets and gate; these nodes
                                   are not templates and set no marker.

The marker is therefore a property of the pushed image, an informational property that
`golden-marker-check` verifies (no host code scans it now). Setting `captureMode` on any
evaluation whose manifest no host reads produces a guest that waits for a
freeze nothing will ask for.

## context-2

Every nameable unit in this evaluation, keyed by full unit name. Whether a
/run/ix reader can be started by the capture boot is not a services-only
question, a target, socket or timer answers it too.

`config.systemd.units` is deliberately absent even though it holds every
unit under one name: NixOS derives it FROM these families, and the derived
entries keep only `wantedBy`/`requiredBy` with `Wants=`/`After=` already
rendered into `text`. Merging it would shadow the typed families with
entries whose forward edges are no longer legible.

## context-3

`systemd.mounts` and `.automounts` are LISTS whose unit names come from
systemd path escaping this module does not implement. Their forward edges
are still edges, so they are handed over unattributed rather than dropped: a
mount that `Wants=` a /run/ix reader must fail the gate, not slip past it
because the gate could not spell the mount's name.

## context-4

Deliberately no `example`. The one this used to carry named
`ix-repersonalize`, a unit that has never existed in this repo, see
the description. An example is the last place a retired name survives a
correction, and a fictional unit name in `nixos-option` output reads as
a thing to go look for.

## context-5

The image's declaration of its capture flow, addressed to the host.
Content ignored; presence is the whole signal. cas-image.nix's systemRoot
copies this file out of the built toplevel into the CAS manifest, and the
node agent scans the manifest for it, that scan is the only reader.

A file rather than a build-time argument so the declaration travels with
the image, which is the thing being varied. The guest daemon deliberately
does not read it (ENG-12588): it is told its mode on the capture-time
Configure, so there is one source per side and no way for the two spellings
to disagree at a call site.

## context-6

Wanted by the default boot so the capture point is reached without
anyone starting it, and After= the same units it is Wanted by. That is
not a cycle: Wants= carries no ordering, so the only ordering edge is
this unit's own After=, and systemd starts it once the boot transaction
it was pulled into has settled.

## context-7

The re-personalization point. Deliberately NOT wanted by the boot: during
the capture boot there is no machine to personalize for, and a target
that activated there would assert the opposite of what it means. The
guest daemon starts it explicitly once this VM's secrets and identity are
on disk: after re-personalizing a restored template, and after the
SIGUSR1 handoff of every other Configure-driven boot that is not a
capture, which is a cold create or a legacy (pre-systemd) restore
(ENG-12588, https://linear.app/indexable/issue/ENG-12588). Its reader is
the unit FILE: when the workload is boot-init, the daemon checks for
`etc/systemd/system/ix-restored.target` in the toplevel vm-init's selector
boots (`handler::configure::unit_declaration_in`), so declaring
this target is what opts an image in, and the host's Running waits for it
on both paths. Every other workload's declaration is read from the same
`etc/systemd/system` under the image root it runs in, by the same code:
NixOS is one image of the general path, and the Ubuntu runner image
(nix/base-images/ubuntu/runner) is another. Renaming the target or dropping it from an image silently
turns the cold raise off for that image.

A unit reading per-machine state is `wantedBy` THIS target, ordered After=
it, and pulled in by nothing else. In particular it must not `Wants=` it.
Wants= carries no ordering but it does pull in both directions, so a unit
the capture boot can already reach would drag this target into the capture
boot with it: the unit reads an empty /run/ix and is frozen that way, and
the target is left ACTIVE inside the snapshot, where it silently satisfies
the daemon's post-restore StartUnit so nothing ever re-runs. That was the
shape this module's own assertion used to prescribe (ENG-12579).

./golden-ordering.nix owns the unit name the gate matches on; a rename
here that misses it refuses every correctly written reader rather than
passing them, so the two cannot drift quietly.
