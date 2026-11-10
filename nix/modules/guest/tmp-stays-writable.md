# tmp-stays-writable.nix notes

Why lines in [tmp-stays-writable.nix](tmp-stays-writable.nix) look the way they do.

## context-1

The image root's `/tmp` is mode 0555. ix's PID 1 mounts a tmpfs over it (`ESSENTIAL_MOUNTS` in crates/vm/guest/remote-bootstrap/src/main.rs), so the 0555 shows only when a mount goes away. Retiring a generation-declared `tmp.mount` did exactly that: a clean switch left `/tmp dr-xr-xr-x root root` and every `DynamicUser` workload broken (2026-07-30).

systemd's `q /tmp 1777` tmpfiles rule does not fix it, because `systemd-tmpfiles-setup.service` reruns on a switch only when its config changed. An activation snippet runs at boot and on every switch. Fixing the image root only reaches guests on recreate; once it is fixed, this snippet is a silent no-op. Its own module so tests/switch-stops-a-mount-vm.nix can import it.
