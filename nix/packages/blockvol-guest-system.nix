# Guest-side policy a block-volume rootfs depends on.
#
# `blockvol-base-artifact.nix` layers this on the index base image and bakes the resulting
# toplevel into the disk. Nothing here is a new decision: every block names the
# document it implements, because the failure mode this module exists to prevent
# is a kernel or nixpkgs bump silently dropping one of them.
#
#   crates/storage/blockvol/design/03-guest-timeout-and-reset.md
#     LOCKED option B: the guest hangs patiently through a backend stall, and the
#     assumption is pinned in the image rather than left implicit in a driver's
#     current behavior. Its image-side obligations are the hung_task block and
#     the sysrq block below.
#   docs/block-volumes/block-volumes-spec.md section 4
#     The guest-filesystem tuning list: mount options, no inline discard, the
#     writeback sysctls, and the io scheduler.
#   docs/block-volumes/block-volumes-spec.md section 9.2
#     Discard is not optional: without fstrim punching holes a thin volume only
#     grows and GC has nothing to collect.
#   tools/ledger-oracle/README.md FINDING 7
#     Guest git creates reftable repositories that guest nix cannot read.
#
# Why a NixOS module rather than files written into the image tree: a NixOS
# guest's /etc/systemd/system is a symlink into the store, so a timer cannot be
# dropped into a built image after the fact, and a hand-written sysctl file next
# to the generated 60-nixos.conf is invisible to anyone reading the
# configuration. Declaring the policy means the built toplevel can be read back
# and asserted against, which is what `blockvol-base-artifact.nix`'s parameter check does.
{
  # Kernel `root=` value the VMM boots with (vm-runtime `BlockVolRootfs`).
  rootDevice ? "/dev/vda",
  # Zoned XFS reclaims realtime zones in the kernel; it does not use FITRIM.
  realtimeDevice ? null,
}: {lib, ...}: {
  # Mount options for the root filesystem (spec section 4).
  #
  # noatime: an atime update turns a pure read into a metadata write, which on a
  # block volume is a log record and a folded extent for nothing.
  # lazytime: keeps in-memory timestamp updates out of the log until the inode
  # is written for another reason, which is what makes a build tree's mtime
  # churn free rather than one journal commit per touched file.
  #
  # NO discard here on purpose: inline discard issues a discard per extent free,
  # in the commit path, which is the burst pattern the log is worst at. Discard
  # is batched instead by the fstrim timer below.
  #
  # This is the steady-state mount. The kernel's own initial mount takes its
  # options from `rootflags=` on the cmdline, which the VMM owns
  # (vm-runtime `Rootfs::kernel_root_args`) and which does not set them today,
  # so early boot runs with kernel defaults until systemd-remount-fs applies
  # this entry. That window is bounded by local-fs.target and touches only the
  # boot path's own reads.
  # This is a ROOT image, and the image's filesystem UUID is pinned
  # (blockvol-base-artifact.nix), so a second volume cloned from it and attached to the
  # same guest would be a duplicate-UUID mount that XFS refuses outright.
  # Nothing does that today; a data-volume image needs its own UUID.
  fileSystems."/" = {
    device = rootDevice;
    fsType = "xfs";
    options =
      [
        "noatime"
        "lazytime"
      ]
      ++ (
        if realtimeDevice == null
        then []
        else ["rtdev=${realtimeDevice}"]
      );
  };

  boot.kernel.sysctl = {
    # --- writeback shaping (spec section 4) -----------------------------------
    #
    # Absolute bytes, not ratios. A ratio is a fraction of guest RAM, so the
    # same image on a 256 GiB VM would let tens of gigabytes of dirty pages
    # accumulate and then hand the backend one enormous writeback storm; the
    # burst the host has to absorb should not be a function of how much memory
    # the tenant bought. Setting `dirty_bytes` makes the kernel treat
    # `dirty_ratio` as 0 and vice versa, so only one of each pair is set.
    #
    # 64 MiB background / 256 MiB throttle: background writeback starts early
    # and stays running so a flush rarely finds a large dirty set, and the hard
    # throttle bounds how much acked-but-unwritten data one writer can queue
    # ahead of the log. The pair is deliberately conservative and is calibrated
    # against sustained fold+log throughput, which is NOT yet measured: G1's
    # numbers review owns the real values (spec open question on writeback
    # shaping). These are a designed starting point, not a tuned result.
    "vm.dirty_background_bytes" = 64 * 1024 * 1024;
    "vm.dirty_bytes" = 256 * 1024 * 1024;

    # --- patient guest (design/03, LOCKED option B) ---------------------------
    #
    # virtio-blk installs no blk-mq `.timeout` handler, so a stalled backend
    # leaves tasks in D-state indefinitely rather than erroring the request:
    # that is the behavior G3's restart transparency depends on, and the only
    # thing the guest can get wrong is how it reacts to the wait.
    #
    # 300 s: well above any vmfsd restart window (target 2 to 5 s, and above a
    # pathologically slow one) so a normal restart never prints a hung-task
    # trace and trains operators to ignore them, while still leaving the
    # detector armed for the minutes-scale stall class design/03 leaves open.
    # Losing the warning entirely would remove the only in-guest signal that a
    # stall is no longer a restart.
    "kernel.hung_task_timeout_secs" = 300;
    # Pinned, not defaulted: panicking on a patient wait would convert a
    # recoverable stall into a dead VM, which is exactly why design/03 rejected
    # host-side request expiry (candidate C).
    "kernel.hung_task_panic" = 0;

    # --- sysrq (design/03 diagnostics, ledger-oracle Hooks item 4) ------------
    #
    # 1 = every function, which includes bit 128 (reboot) that the oracle's
    # guest-reset fault leg needs; the harness marks the leg SKIP rather than
    # substituting another fault, so a restrictive mask here silently deletes a
    # durability test. The dump functions (t, w, l) are the other half of the
    # reason: for the minutes-scale stall design/03 leaves open, a task dump is
    # the only way to see from inside the guest that it is blocked on IO. The
    # guest is single-tenant and its owner can already reboot the VM through the
    # API, so this grants no authority the tenant lacks.
    "kernel.sysrq" = 1;
  };

  # Batched discard (spec section 9.2). fstrim's own unit already skips
  # filesystems whose device does not support discard (`--quiet-unsupported`),
  # so this is safe to ship before the VMM advertises VIRTIO_BLK_F_DISCARD; it
  # is a no-op until then rather than a boot-time error.
  #
  # Pinned explicitly even though nixpkgs currently defaults it on: an upstream
  # default flipping back is a silent loss of the only thing that lets a thin
  # volume shrink.
  services.fstrim = {
    enable = realtimeDevice == null;
    interval = "weekly";
  };

  # The post-GC hook. `nix-collect-garbage` is what frees most of a build VM's
  # blocks, and a weekly timer means those blocks stay allocated on the host for
  # up to a week after the guest stopped using them.
  #
  # OnSuccess covers the unit path (`nix.gc.automatic`, `systemctl start
  # nix-gc`). A bare `nix-collect-garbage` in a shell is not a unit and cannot
  # be hooked from here, so the documented manual hook is
  # `systemctl start --no-block fstrim.service`, which is also what the
  # ledger-oracle's discard leg drives.
  systemd.services.nix-gc.unitConfig.OnSuccess = lib.optional (realtimeDevice == null) "fstrim.service";

  # IO scheduler: none. The host is the scheduler (spec section 4) - reordering
  # in the guest only delays requests the backend is going to order by LSN
  # anyway, and it hides the request pattern the fold engine is being measured
  # against. The root filesystem is already mounted by the time this runs, so
  # what it governs is the workload's IO, not the boot path's.
  #
  # A oneshot service rather than the usual udev rule because this guest runs
  # with udev disabled (`services.udev.enable = false` follows from
  # boot.isContainer), so a rule file would be silently inert: exactly the class
  # of drift this module exists to prevent. It also means nothing re-runs this,
  # so a device that appears after boot keeps the kernel's default scheduler
  # until something restarts the unit.
  systemd.services.ix-block-queue-policy = {
    description = "Pin the block-volume IO scheduler (block-volumes-spec section 4)";
    wantedBy = ["sysinit.target"];
    before = ["local-fs.target" "shutdown.target"];
    # DefaultDependencies=false to run this early; that also drops the implicit
    # ordering against shutdown, which has to be restored by hand or the unit
    # can be started while the system is going down.
    unitConfig = {
      DefaultDependencies = false;
      Conflicts = ["shutdown.target"];
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    # Every virtio-blk device the guest has at boot, not just the root one, so a
    # second disk is not silently left on a different scheduler. A device
    # already set to `none` (which is the kernel's own default for a
    # multi-queue device) is written anyway; the kernel accepts that as a no-op.
    script = ''
      shopt -s nullglob
      for queue in /sys/block/vd*/queue; do
        if [ -w "$queue/scheduler" ]; then
          echo none > "$queue/scheduler"
        fi
      done
    '';
  };

  # Guest git must create files-format repositories (ledger-oracle FINDING 7).
  #
  # Guest git creates reftable repositories by default, and guest nix's libgit2
  # cannot open one: `git clone` succeeds, `git fsck` is clean, and the
  # subsequent `nix build` dies with "unsupported extension name
  # extensions.refstorage". That presents as an instant build failure on a fresh
  # volume, which reads exactly like a storage bug and is not one. The
  # acceptance workload works around it per-clone; pinning it here fixes it for
  # every clone in the VM, including the ones a user makes.
  #
  # System scope is git's lowest precedence, so a user who wants reftable still
  # gets it by setting it anywhere else.
  # `enable` is set here too, even though the base profile already sets it: this
  # module's whole job is that the policy cannot be lost, and
  # `environment.etc.gitconfig` only exists when git is enabled. Inheriting that
  # precondition from another module would mean this pin disappears silently if
  # that module changes.
  programs.git = {
    enable = true;
    config.init.defaultRefFormat = "files";
  };

  # design/03 candidate B also asks for `/sys/block/<dev>/device/timeout` "where
  # it exists". It does not exist here: that attribute belongs to the SCSI disk
  # class, and virtio-blk exposes no per-device timeout knob. The hung_task
  # tuning above is therefore the whole of the guest-side timeout policy, and
  # the queue-policy service is the only thing writing into /sys/block.
}
