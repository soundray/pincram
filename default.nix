{ pkgs ? import <nixpkgs> {} }:

let
  inherit (pkgs) lib;

  src = lib.cleanSource ./.;

  binpath = lib.makeBinPath [
    pkgs.mirtk
    pkgs.niftyseg
    pkgs.coreutils
    pkgs.findutils
    pkgs.gawk
    pkgs.gnugrep
    pkgs.gnused
    pkgs.gnutar
    pkgs.bc
    pkgs.util-linux
  ];
in

pkgs.runCommand "pincram" {} ''
  mkdir -p "$out/bin" "$out/lib/pincram"

  cp ${src}/{pincram.sh,reg.sh,atlas-csv-gen.sh,atlas-gen.sh,distrib,spark,functions,neutral.dof.gz} \
    "$out/lib/pincram/"

  chmod u+w "$out/lib/pincram/functions"

  cat >> "$out/lib/pincram/functions" <<EOF2

export PATH="${binpath}:\$PATH"
EOF2

  for f in \
    pincram.sh reg.sh atlas-csv-gen.sh atlas-gen.sh distrib spark
  do
    chmod +x "$out/lib/pincram/$f"
    patchShebangs "$out/lib/pincram/$f"
  done

  ln -s "$out/lib/pincram/pincram.sh" "$out/bin/pincram"
  ln -s "$out/lib/pincram/atlas-gen.sh" "$out/bin/pincram-atlas-gen"
''
