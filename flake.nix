{
  description = "Pincram brain extraction";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      pincram = import ./default.nix { inherit pkgs; };
    in {
      packages.${system} = {
        inherit pincram;
        default = pincram;
      };
    };
}
