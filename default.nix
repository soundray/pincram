{ pkgs ? import <nixpkgs> {}, version ? "unknown" }:

let
  inherit (pkgs) lib;

  src = lib.cleanSource ./.;

  python = pkgs.python3.withPackages (ps: [ ps.numpy ps.scipy ps.nibabel ]);

  binpath = lib.makeBinPath [
    pkgs.mirtk
    python
    pkgs.coreutils
    pkgs.findutils
    pkgs.gawk
    pkgs.gnugrep
    pkgs.gnused
  ];
in

pkgs.runCommand "pincram" {} ''
  mkdir -p "$out/bin" "$out/lib/pincram"

  cp ${src}/{pincram.sh,reg.sh,pincram-image,atlas-csv-gen.sh,atlas-gen.sh,scheduler,functions,neutral.dof.gz} \
    "$out/lib/pincram/"

  # pincram-image needs the Python with numpy, scipy and nibabel; patchShebangs would look python3
  # up on the build PATH, which does not have it
  chmod u+w "$out/lib/pincram/pincram-image"
  sed -i "1s|.*|#!${python}/bin/python3|" "$out/lib/pincram/pincram-image"

  # short commit SHA, reported by pincram.sh at the start of each run
  echo ${lib.escapeShellArg version} >"$out/lib/pincram/VERSION"

  chmod u+w "$out/lib/pincram/functions"

  cat >> "$out/lib/pincram/functions" <<EOF2

export PATH="${binpath}:\$PATH"
EOF2

  for f in \
    pincram.sh reg.sh pincram-image atlas-csv-gen.sh atlas-gen.sh
  do
    chmod +x "$out/lib/pincram/$f"
    patchShebangs "$out/lib/pincram/$f"
  done

  ln -s "$out/lib/pincram/pincram.sh" "$out/bin/pincram"
  ln -s "$out/lib/pincram/atlas-gen.sh" "$out/bin/pincram-atlas-gen"
  ln -s "$out/lib/pincram/pincram-image" "$out/bin/pincram-image"
''
