# Coreutils on the guest's PATH start in a third of the time NixOS's default ones do.
#
# Why: NixOS puts `coreutils-full` on the system path. Every program in it is one 1.7 MB multicall binary
# linked against libcrypto (OpenSSL), libgmp, libacl and libattr, so even `true` maps and relocates all of
# them on every exec. Build scripts, configure runs and cargo/nix builds run these tools thousands of times.
# Measured per fork+exec of `true` from dash, ix guest kernel, 96 vCPUs, cold-booted QEMU/KVM guest on
# Graviton4 (2026-10-17, CREATEGAP):
#   coreutils-full (multicall, ssl+gmp+acl+attr)   850-870 us
#   coreutils      (multicall, gmp+acl+attr)       480 us
#   multicall, acl+attr only                       400-420 us
#   separate binaries, acl+attr only (this)        250-260 us
#   Debian 12 /bin/true                            220-230 us
# Same order on Graviton5: coreutils-full 720-740 us, lean separate binaries 220 us. In an ix golden-claim VM
# on Graviton5 the ixbase image's `true` takes 900-980 us (288 page faults per exec) against 180-200 us for
# debian:12's (42 faults).
#
# How: a coreutils build with one binary per program and no GMP (only `expr` and `factor` use it, for numbers
# beyond 64 bits), at high priority so its programs win the system path over coreutils-full's. ACL and xattr
# support stay (cp/mv/ls keep them), and OpenSSL was never in plain coreutils.
{
  lib,
  pkgs,
  ...
}: {
  environment.systemPackages = [
    (lib.hiPrio (pkgs.coreutils.override {
      singleBinary = false;
      gmpSupport = false;
    }))
  ];
}
