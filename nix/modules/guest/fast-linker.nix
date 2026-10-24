# Rust links with mold by default in ix guests.
#
# Why: in the edit loop, a one-crate change in rust-analyzer spends 6.5 of 7.0 s linking with GNU ld (x86, bare metal),
# and 13.5 s inside a VM. With mold the whole rebuild is 0.46 s (lld 1.2 s, wild 0.57 s), about 10x faster, and that holds
# for every Rust project. Source: docs/bench/fastvm-baseline-2026-10-16.md, breakdown phases ralink-*.
#
# How: `/.cargo/config.toml` is an ancestor of every working directory, so cargo reads it for every project and every
# user. It sets only the per-target `linker`: a `cc` wrapper that runs the C compiler on PATH with `-B <dir>`, where
# `<dir>` holds `ld` pointing at nixpkgs' wrapped mold (the ld-wrapper keeps the Nix rpath/flags handling). gcc and clang
# look for `ld` in -B dirs first, so this works without mold on PATH, including in `nix develop --pure` shells.
#
# It must not set rustflags: cargo takes rustflags from exactly one source and `[target.<triple>]` beats `[build]`, so a
# guest-wide target rustflags would silently replace every project's `[build] rustflags` (tokio_unstable, target-cpu,
# -D warnings). `linker` is a single value, so the nearest config wins and nothing else is touched.
#
# Overriding, per project or per shell:
# - `[target.<triple>] linker = "cc"` in the project's .cargo/config.toml (a nearer config wins);
# - `CARGO_TARGET_<TRIPLE>_LINKER=cc`;
# - `-C link-arg=-fuse-ld=lld` (or bfd) in the project's rustflags: gcc then looks for that linker instead of the -B `ld`.
# wild is installed too: `-C link-arg=-B<wild dir>` or `-C linker=clang -C link-arg=--ld-path=wild`.
{
  lib,
  pkgs,
  ...
}: let
  # `ld` -> wrapped mold, in a directory of its own, for gcc's/clang's -B lookup
  moldLd = pkgs.runCommand "ix-mold-ld" {} ''
    mkdir -p $out/bin
    ln -s ${pkgs.mold}/bin/ld.mold $out/bin/ld
  '';
  # A compiled (makeBinaryWrapper) `cc` that runs `env cc -B<moldLd> "$@"`: env resolves the user's C compiler on PATH.
  # Named `cc` so rustc infers the gcc linker flavor. It is referenced by absolute path and never put on PATH, so the
  # `cc` env finds is the user's, not itself.
  moldCc = pkgs.runCommand "ix-mold-cc" {nativeBuildInputs = [pkgs.makeBinaryWrapper];} ''
    makeBinaryWrapper ${pkgs.coreutils}/bin/env $out/bin/cc --add-flags "cc -B${moldLd}/bin"
  '';
  cargoConfig = pkgs.writeText "ix-cargo-config.toml" ''
    # ix guest default (nix/modules/guest/fast-linker.nix): Rust links with mold. Override per project with
    # `[target.<triple>] linker = "cc"`, or CARGO_TARGET_<TRIPLE>_LINKER. Sets no rustflags on purpose.
    [target.x86_64-unknown-linux-gnu]
    linker = "${moldCc}/bin/cc"
    [target.aarch64-unknown-linux-gnu]
    linker = "${moldCc}/bin/cc"
  '';
  # Built with the image: a project's own `[build] rustflags` survive the guest-wide config, and the binary is linked
  # by mold.
  projectRustflagsSurvive =
    pkgs.runCommand "ix-fast-linker-keeps-project-rustflags" {
      nativeBuildInputs = [pkgs.cargo pkgs.rustc pkgs.stdenv.cc pkgs.binutils];
    } ''
      root=$TMPDIR/root
      mkdir -p $root/.cargo $root/proj/.cargo $root/proj/src
      cp ${cargoConfig} $root/.cargo/config.toml
      cat > $root/proj/.cargo/config.toml <<'EOF'
      [build]
      rustflags = ["--cfg", "ix_project_flag"]
      EOF
      cat > $root/proj/Cargo.toml <<'EOF'
      [package]
      name = "t"
      version = "0.1.0"
      edition = "2021"
      [lints.rust]
      unexpected_cfgs = { level = "warn", check-cfg = ["cfg(ix_project_flag)"] }
      EOF
      cat > $root/proj/src/main.rs <<'EOF'
      #[cfg(not(ix_project_flag))]
      compile_error!("the guest-wide cargo config replaced the project's [build] rustflags");
      fn main() {}
      EOF
      cd $root/proj
      HOME=$TMPDIR CARGO_HOME=$TMPDIR/cargo-home cargo build --offline
      ./target/debug/t
      readelf -p .comment target/debug/t | grep -q mold
      touch $out
    '';
in {
  environment.systemPackages = [pkgs.mold] ++ lib.optional (pkgs ? wild) pkgs.wild;
  system.checks = [projectRustflagsSurvive];
  systemd.tmpfiles.rules = [
    "d /.cargo 0755 root root -"
    # L: create the link only when nothing is there, so an image or a user that put its own file there keeps it
    "L /.cargo/config.toml - - - - ${cargoConfig}"
  ];
}
