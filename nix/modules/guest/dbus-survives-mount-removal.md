# dbus-survives-mount-removal.nix notes

Why lines in [dbus-survives-mount-removal.nix](dbus-survives-mount-removal.nix) look the way they do.

## context-1

nixpkgs' dbus.nix sets `RequiresMountsFor = ["/tmp"]` on dbus-broker for ordering, but its `Requires=` half stops the bus whenever systemd stops tmp.mount. After guest `/tmp` moved off tmpfs (`dac64977`), a switch stopped the retired tmp.mount, took the bus down mid-transaction, and switch-to-configuration exited 1 with `disconnected from D-Bus?`. The generation never advanced and the exposed rootfs `/tmp` stayed 0555 (ENG-11080).

`WantsMountsFor=` keeps the `After=` edge (systemd adds it for every mount-dependency type, `unit_add_mount_dependencies()` in src/core/unit.c) and drops stop, restart and start-gate propagation. The lost start gate does not matter because these guests have no tmp.mount to fail.

`PrivateTmp=true` plus a reload after `/tmp` is replaced fails with `226/NAMESPACE` in systemd#28515, but not on systemd 261. tests/switch-stops-a-mount-vm.nix keeps that reload so a regression fails there first; its `machine.fail` on `Requires=tmp.mount` also catches an upstream reshape.

The first switch onto this module still behaves the old way, because switch-to-configuration reads the running generation's units. ENG-11080 has the manual step for guests still on tmpfs `/tmp`. This is its own module so the VM test can import it; lib/image/platform.nix cannot be instantiated in a test VM. Not yet sent upstream.

## context-2

nixpkgs defines dbus-broker.service only under `implementation == "broker"`, and `services.dbus.enable` defaults off. Unguarded, this module would create a dbus-broker.service with no ExecStart on hosts using the reference daemon.
