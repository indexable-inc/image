{
  config,
  lib,
  pkgs,
  ...
}: let
  declaredTmpfsSize = options: let
    sized = builtins.filter (option: lib.hasPrefix "size=" option) options;
  in
    if sized == []
    then null
    else lib.removePrefix "size=" (lib.last sized);
  ramSizedMount = mountPoint: fsType: options: let
    size = declaredTmpfsSize options;
  in
    lib.optional (fsType == "tmpfs" && size != null) {
      mountpoint = mountPoint;
      inherit size;
    };
  ramSizedMountsIn = fileSystemAttrs:
    lib.concatLists (
      lib.mapAttrsToList (
        mountPoint: fs: ramSizedMount mountPoint fs.fsType fs.options
      )
      fileSystemAttrs
    );
  # `boot.specialFileSystems` is where /run and /dev/shm get their fractions,
  # `fileSystems` is any tmpfs the image declares itself, and `systemd.mounts`
  # is where `boot.tmp.useTmpfs = true` lands /tmp.
  ramSizedTmpfsMounts =
    ramSizedMountsIn config.boot.specialFileSystems
    ++ ramSizedMountsIn config.fileSystems
    ++ lib.concatLists (
      map (
        mount:
          ramSizedMount mount.where mount.type (
            lib.splitString "," (mount.options or "")
            ++ lib.splitString "," (mount.mountConfig.Options or "")
          )
      )
      config.systemd.mounts
    );
in {
  config = {
    boot = {
      isContainer = true;
      # See ./platform.md#context-1.
      modprobeConfig.enable = lib.mkForce true;
      # See ./platform.md#context-2.
      tmp = {
        useTmpfs = lib.mkDefault false;
        # See ./platform.md#context-3.
      };
    };
    # See ./platform.md#context-4.
    environment.etc."ix/tmpfs-sizing.json".source = (pkgs.formats.json {}).generate "ix-tmpfs-sizing.json" {
      mounts = ramSizedTmpfsMounts;
    };
    # See ./platform.md#context-5.
    programs.nix-ld.enable = lib.mkDefault true;
    networking = {
      # See ./platform.md#context-6.
      useDHCP = false;
      # See ./platform.md#context-7.
      resolvconf.enable = lib.mkDefault false;
      # See ./platform.md#context-8.
      nftables.enable = true;
      firewall = {
        enable = lib.mkDefault true;
        allowedTCPPorts = [
          5001 # ix-console shell and terminal snapshot listener.
        ];
        allowedUDPPorts = [
          8443 # ix-agent WebTransport direct-connect endpoint.
        ];
      };
    };
    services = {
      # See ./platform.md#context-9.
      journald.settings.Journal.SystemMaxUse = lib.mkDefault "1G";
      # See ./platform.md#context-10.
      userdbd = {
        enable = true;
        # See ./platform.md#context-11.
        silenceHighSystemUsers = true;
      };
    };
    # See ./platform.md#context-12.
    systemd.services = {
      "serial-getty@ttyS0".enable = false;
      "serial-getty@hvc0".enable = false;
      # See ./platform.md#context-13.
      ix-serial-getty = {
        description = "Rescue serial login prompt on ttyS0";
        documentation = ["man:agetty(8)"];
        wantedBy = ["multi-user.target"];
        # Ordering only, never a dependency: a rescue shell that refuses to
        # start because a normal-boot unit failed is not a rescue shell.
        after = ["systemd-user-sessions.service"];
        # A switch must not kill the session an operator is using to debug the
        # switch. Same reasoning nixpkgs applies to its own gettys.
        restartIfChanged = false;
        unitConfig.ConditionPathExists = "/dev/ttyS0";
        serviceConfig = {
          ExecStart = "${pkgs.util-linux}/sbin/agetty --keep-baud --noclear --autologin root ttyS0 115200 vt100";
          Type = "idle";
          Restart = "always";
          RestartSec = 5;
          UtmpIdentifier = "ttyS0";
          TTYPath = "/dev/ttyS0";
          TTYReset = true;
          TTYVHangup = true;
          KillMode = "process";
          IgnoreSIGPIPE = false;
          SendSIGHUP = true;
          StandardInput = "tty";
          StandardOutput = "tty";
        };
      };
    };
    # See ./platform.md#context-14.
    systemd.coredump = {
      enable = true;
      settings.Coredump = {
        Storage = "external";
        Compress = "yes";
        MaxUse = "5G";
      };
    };
    # See ./platform.md#context-15.
    nix = {
      # See ./platform.md#context-16.
      nixPath = ["nixpkgs=${pkgs.path}"];
      settings = {
        experimental-features = [
          "nix-command"
          "flakes"
          "pipe-operators"
          "fetch-closure"
          "fetch-tree"
          "ca-derivations"
          # See ./platform.md#context-17.
          "dynamic-derivations"
          "git-hashing"
          # See ./platform.md#context-18.
        ];
        allow-import-from-derivation = lib.mkDefault true;
        warn-dirty = false;
        # See ./platform.md#context-19.
        sandbox-fallback = lib.mkForce true;
      };
      gc = {
        automatic = true;
        options = "--delete-older-than 30d";
      };
      # See ./platform.md#context-15.
      optimise.automatic = false;
      # See ./platform.md#context-20.
      daemonCPUSchedPolicy = "other";
      daemonIOSchedClass = "best-effort";
    };
    # See ./platform.md#context-21.
    system.activationScripts = {
      binsh = lib.mkForce "";
      usrbinenv = lib.mkForce "";
      # See ./platform.md#context-22.
      fhsCompatLinks = ''
        heal() {
          # $1 = FHS entry, $2 = the path it should point at instead.
          if [ -L "$1" ] && [ ! -e "$1" ]; then
            echo "platform: $1 dangles, repointing at $2"
            ln -sfn "$2" "$1"
          fi
        }
        heal /bin /run/current-system/sw/bin
        heal /sbin /run/current-system/sw/sbin
        heal /usr /run/current-system/sw
      '';
    };
    system.stateVersion = "25.05";
  };
}
