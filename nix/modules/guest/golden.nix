# See ./golden.md#context-1.
{
  config,
  lib,
  ...
}: let
  cfg = config.ix.golden;
  ordering = import ./golden-ordering.nix {inherit lib;};
  # See ./golden.md#context-2.
  units =
    lib.concatMapAttrs (
      suffix: family:
        lib.mapAttrs' (name: unit: lib.nameValuePair "${name}.${suffix}" unit) family
    ) {
      path = config.systemd.paths;
      service = config.systemd.services;
      slice = config.systemd.slices;
      socket = config.systemd.sockets;
      target = config.systemd.targets;
      timer = config.systemd.timers;
    };
  # See ./golden.md#context-3.
  anonymousPulls = builtins.concatMap ordering.forwardPulls (
    config.systemd.mounts ++ config.systemd.automounts
  );
in {
  options.ix.golden = {
    captureAfter = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["multi-user.target"];
      example = ["multi-user.target" "ix-agent.service"];
      description = ''
        Units `ix-golden.target` orders itself after and pulls in. The capture
        point is reached once all of them have settled, so this is the list
        that decides what is guaranteed warm in the golden snapshot.

        Widening it delays capture and warms more; narrowing it captures
        sooner and leaves the rest of boot to be paid on every restore.
      '';
    };
    captureMode = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Ship `/etc/ix/golden-boot-capture`, the marker by which this image
        declares to the HOST that it was built for boot-then-capture -- boot
        all the way under systemd, freeze the running machine, re-personalize
        on restore.

        The host is the only reader. A native capture reads the file
        off the image's own disk through the guest daemon
        (`golden::capture::image_disk`). `packages/cas-image.nix` also mirrors
        the marker into the CAS manifest, and
        `ix-closure-manifest golden-marker-check` fails the image build if the
        manifest key and the rootfs copy disagree.

        The guest daemon does NOT read it (ENG-12588). It is told its mode
        explicitly, on the capture-time `Configure`, because the daemon serving
        a boot-then-capture guest -- capture VM and restored VM alike -- is the
        one streamed in before this image existed and could never see the file.
        A daemon-side read of it was false on exactly those guests.

        So this option is only meaningful on a PUSHED image, whose manifest a
        host actually scans. Setting it on the base block image instead is
        ENG-12402: it declares a flow to a manifest nothing reads.

        Off by default so images built from this module keep today's
        pre-boot-capture behavior until the rollout is finished. `.#casImage`
        and `.#casImageCaptureMode` are the two buildable images; flipping the
        default is the last step, not the first.
      '';
    };
    stateWriters = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      # See ./golden.md#context-4.
      description = ''
        Service names (without the `.service` suffix) exempt from the
        post-restore ordering assertion because they WRITE the per-machine
        state under /run/ix rather than read it.

        Empty, with no setter anywhere in the repo, and that is the honest
        state of it: the only thing writing /run/ix today is the guest daemon,
        which is a streamed child of PID 1 with no systemd unit at all, so it
        is not a subject of the gate and has nothing to be exempted from.
        ENG-12579 corrected an earlier version of this text that described it
        as "the guest daemon's re-personalization unit", and ENG-12588 removed
        the last echo of that unit, an `example` naming it. There is no such
        unit and the design precludes one.

        The option stays for the writer that IS a unit, which cannot order
        itself after the target it is itself responsible for reaching and so
        would have no other way past the gate. Nothing else belongs here: an
        entry that turns out to be a reader is an unguarded reader.
      '';
    };
  };
  config = {
    # See ./golden.md#context-5.
    environment.etc = lib.mkIf cfg.captureMode {
      "ix/golden-boot-capture".text = "";
    };
    # The capture point. The guest daemon watches for this target going active
    # and signals the host, which freezes the VM; everything ordered Before= it
    # is therefore warm in the snapshot every restore resumes from.
    systemd.targets.ix-golden = {
      description = "ix golden-snapshot capture point";
      after = cfg.captureAfter;
      wants = cfg.captureAfter;
      # See ./golden.md#context-6.
      wantedBy = ["multi-user.target"];
    };
    # See ./golden.md#context-7.
    systemd.targets.ix-restored = {
      description = "ix post-restore re-personalization complete";
    };
    assertions =
      map (finding: {
        assertion = false;
        inherit (finding) message;
      }) (ordering.findings {
        inherit anonymousPulls units;
        inherit (cfg) stateWriters;
      });
  };
}
