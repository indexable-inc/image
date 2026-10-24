# See ./golden-ordering.md#context-1.
{lib}: let
  restoredTarget = "ix-restored.target";
  # The per-machine state the guest daemon materializes after a restore. Empty
  # during the capture boot by construction: nothing has created a machine for
  # it to describe.
  perMachinePaths = [
    "/run/ix/secrets"
    "/run/ix/config"
  ];
  # Stands in for a unit this evaluation cannot name (see `anonymousPulls`).
  # Never a key in `units`, so it can never be proven post-restore-only, which
  # is the point: an edge from something unnameable is a capture-boot edge.
  unnameablePuller = "a systemd.mounts or systemd.automounts entry";
  # serviceConfig values are strings, lists, paths, ints or bools depending on
  # the directive. Flatten to the strings a path can appear in; nothing else
  # can carry one.
  stringsOf = value:
    if builtins.isList value
    then builtins.concatMap stringsOf value
    else lib.optional (builtins.isString value || builtins.isPath value) (toString value);
  readsPerMachineState = text: lib.any (path: lib.hasInfix path text) perMachinePaths;
  # See ./golden-ordering.md#context-2.
  isWatchedDirective = name:
    builtins.elem name [
      "EnvironmentFile"
      "LoadCredential"
      "LoadCredentialEncrypted"
    ]
    || lib.hasPrefix "ExecStart" name;
  offendingDirectives = unit: let
    serviceConfig = unit.serviceConfig or {};
    watched = builtins.filter isWatchedDirective (builtins.attrNames serviceConfig);
  in
    builtins.filter (
      name: lib.any readsPerMachineState (stringsOf serviceConfig."${name}")
    )
    watched;
  # See ./golden-ordering.md#context-3.
  edgeUnits = option: directive: unit:
    (unit."${option}" or [])
    ++ builtins.concatMap (lib.splitString " ") (
      stringsOf (unit.unitConfig."${directive}" or [])
    );
  afterUnits = edgeUnits "after" "After";
  # Every directive that puts ANOTHER unit into this unit's transaction, in both
  # spellings. `PartOf=` is deliberately absent: it propagates stop and restart,
  # not activation.
  forwardPulls = unit:
    builtins.concatMap (edge: edgeUnits edge.option edge.directive unit) [
      {
        option = "wants";
        directive = "Wants";
      }
      {
        option = "requires";
        directive = "Requires";
      }
      {
        option = "bindsTo";
        directive = "BindsTo";
      }
      {
        option = "upholds";
        directive = "Upholds";
      }
    ];
  # See ./golden-ordering.md#context-4.
  reversePulls = unit:
    builtins.concatMap (option: unit."${option}" or []) [
      "wantedBy"
      "requiredBy"
      "upheldBy"
    ];
in {
  inherit forwardPulls restoredTarget;
  # See ./golden-ordering.md#context-5.
  findings = {
    units,
    anonymousPulls ? [],
    stateWriters ? [],
  }: let
    # Forward edges indexed by the unit they name, so each unit's pullers are
    # one lookup rather than a scan of the whole graph.
    pullersByTarget = lib.mapAttrs (_: edges: map (edge: edge.puller) edges) (
      lib.groupBy (edge: edge.target) (
        lib.concatLists (
          lib.mapAttrsToList (
            puller: unit: map (target: {inherit puller target;}) (forwardPulls unit)
          )
          units
        )
      )
    );
    # Everything that can put `name` into a transaction: its own reverse edges,
    # every unit whose forward edges name it, and the unnameable families.
    pullersOf = name:
      lib.unique (
        reversePulls (units."${name}" or {})
        ++ (pullersByTarget."${name}" or [])
        ++ lib.optional (builtins.elem name anonymousPulls) unnameablePuller
      );
    # See ./golden-ordering.md#context-6.
    grow = reached: let
      next =
        reached
        ++ builtins.filter (
          name: let
            pullers = pullersOf name;
          in
            !(builtins.elem name reached)
            && pullers != []
            && lib.all (puller: builtins.elem puller reached) pullers
        ) (builtins.attrNames units);
    in
      if builtins.length next == builtins.length reached
      then reached
      else grow next;
    postRestoreOnly = grow [restoredTarget];
    # The target is the one unit whose premature activation both leaks and hides
    # the leak, so its containment is checked on its own rather than per reader.
    targetPullers = pullersOf restoredTarget;
    containment = lib.optional (targetPullers != []) {
      unit = restoredTarget;
      message = ''
        ix.golden: ${lib.concatStringsSep ", " targetPullers} pulls ${restoredTarget} into the capture boot.

        ${restoredTarget} names the moment this machine's per-machine state exists under /run/ix. No machine exists during the capture boot, so the target must not activate there: anything ordered after it would run against an empty /run/ix and be frozen that way. Worse, a target already active inside the snapshot satisfies the guest daemon's post-restore StartUnit the moment it is asked, so RestoreComplete latches, the host accepts the boot, and the units hanging off the target never re-run against the real secrets on any restored VM.

        Fix: nothing may name ${restoredTarget} in wants, requires, bindsTo or upholds (Wants= pulls in both directions). A unit that must run after a restore declares wantedBy = [ "${restoredTarget}" ] and lets the guest daemon start the target.
      '';
    };
    readers =
      lib.filterAttrs (
        name: unit:
          lib.hasSuffix ".service" name
          && !(builtins.elem (lib.removeSuffix ".service" name) stateWriters)
          && offendingDirectives unit != []
      )
      units;
    readerFinding = name: unit: let
      short = lib.removeSuffix ".service" name;
      pullers = pullersOf name;
      capturePullers = builtins.filter (puller: !(builtins.elem puller postRestoreOnly)) pullers;
      reasons =
        lib.optional (!(builtins.elem restoredTarget (afterUnits unit)))
        "it is not ordered After=${restoredTarget}"
        ++ lib.optional (pullers == [])
        "nothing in this evaluation pulls it in, so no restore would start it either"
        ++ lib.optional (capturePullers != [])
        "the capture boot can start it through ${lib.concatStringsSep ", " capturePullers}";
    in
      lib.optional (reasons != []) {
        unit = name;
        message = ''
          ix.golden: systemd unit ${name} reads this machine's state under /run/ix via ${
            lib.concatStringsSep ", " (offendingDirectives unit)
          }, but ${lib.concatStringsSep "; and " reasons}.

          This guest is captured as a golden snapshot after it has booted, and /run/ix is empty at capture time. A unit the capture boot can reach starts there, reads nothing, and its empty secrets are frozen into the snapshot -- a snapshot shared by every machine created from this image, so every one of them runs a unit configured from no machine's secrets, with no error and nothing in any journal to find it by.

          Fix: make a restore the only thing that can start it.

            systemd.services.${short}.wantedBy = [ "${restoredTarget}" ];
            systemd.services.${short}.after = [ "${restoredTarget}" ];

          and nothing else in wantedBy or requiredBy -- in particular not "multi-user.target", which IS the capture boot. Do NOT add "${restoredTarget}" to wants: Wants= pulls in both directions, so a unit the capture boot already reaches would drag the target into the capture boot with it and still be frozen having read nothing.

          If this unit WRITES /run/ix rather than reading it, list "${short}" in ix.golden.stateWriters instead.
        '';
      };
  in
    containment ++ lib.concatLists (lib.mapAttrsToList readerFinding readers);
}
