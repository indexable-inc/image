/**
   Pre-fill Nix's fetcher cache with the image's own nixpkgs, so the registry pin
   `github:NixOS/nixpkgs/<rev>` resolves locally on first use.

   Nix fetches a `github:` input by unpacking its tarball into the Git tarball cache
   (~/.cache/nix/tarball-cache-v2) and recording `gitRevToTreeHash` and `gitRevToLastModified`
   for the rev in ~/.cache/nix/fetcher-cache-v4.sqlite (libfetchers/github.cc). When both rows
   exist and the tree is in the cache, it does neither the download nor the unpack: 14-18 s on the
   first `nix ... nixpkgs#x` in a fresh VM without this, 0.18 s with it (Determinate Nix 3.23.1,
   2026-10-17). The pin stays a `github:` input, so a flake.lock written in a VM names
   GitHub with rev and narHash and works anywhere.

   Returns `{ pack, script }`: `pack` is a store path holding one Git packfile with the source
   tree (the same tree Nix's tarball import makes: `git write-tree` of the source equals the
   recorded `treeHash`), `script` a shell function body that seeds one home directory: the pack
   linked into its tarball cache (the cache wants packfiles only) and the three cache rows, the
   third (`sourcePathToHash`) sparing the NAR hash of the 400 MB tree.
*/
{
  pkgs,
  nixpkgs,
}: let
  pack = pkgs.runCommand "nixpkgs-tarball-cache-pack" {nativeBuildInputs = [pkgs.git];} ''
    export GIT_DIR=$TMPDIR/repo GIT_INDEX_FILE=$TMPDIR/index
    git init -q --bare "$GIT_DIR"
    # -f: the source's own .gitignore files must not drop files the tarball has.
    GIT_WORK_TREE=${nixpkgs.outPath} git add -A -f .
    tree=$(git write-tree)
    git update-ref refs/tags/source "$tree"
    git -c pack.threads=1 repack -a -d -q
    mkdir -p "$out"
    cp "$GIT_DIR"/objects/pack/pack-*.pack "$GIT_DIR"/objects/pack/pack-*.idx "$out"/
    echo "$tree" > "$out/tree"
  '';
in {
  inherit pack;
  # `seed_home HOME OWNER GROUP`. Idempotent; a home with its own cache keeps it.
  script = ''
    seed_home() {
      local home=$1 owner=$2 group=$3
      local cache=$home/.cache/nix repo=$home/.cache/nix/tarball-cache-v2
      install -d -o "$owner" -g "$group" "$home/.cache" "$cache" "$repo" "$repo/objects" \
        "$repo/objects/pack" "$repo/objects/info" "$repo/refs" "$repo/refs/heads" "$repo/refs/tags"
      [ -e "$repo/HEAD" ] || printf 'ref: refs/heads/master\n' > "$repo/HEAD"
      [ -e "$repo/config" ] || printf '[core]\n\tbare = true\n\trepositoryformatversion = 0\n\tfilemode = true\n' > "$repo/config"
      for file in ${pack}/pack-*; do
        ln -sfn "$file" "$repo/objects/pack/''${file##*/}"
      done
      local tree
      tree=$(cat ${pack}/tree)
      sqlite3 "$cache/fetcher-cache-v4.sqlite" <<SQL
    create table if not exists Cache (domain text not null, key text not null, value text not null, timestamp integer not null, primary key (domain, key));
    insert or replace into Cache values ('gitRevToTreeHash', '{"rev":"${nixpkgs.rev}"}', '{"treeHash":"$tree"}', 1);
    insert or replace into Cache values ('gitRevToLastModified', '{"rev":"${nixpkgs.rev}"}', '{"lastModified":${toString nixpkgs.lastModified}}', 1);
    insert or replace into Cache values ('sourcePathToHash', '{"fingerprint":"git:$tree","method":"nar","path":"/"}', '{"hash":"${nixpkgs.narHash}"}', 1);
    SQL
      chown -h "$owner:$group" "$repo/HEAD" "$repo/config" "$cache/fetcher-cache-v4.sqlite" "$repo"/objects/pack/pack-*
    }
  '';
}
