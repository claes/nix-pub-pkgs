{
  description = "Custom Nix packages with an S3 binary cache";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      packageEntries = builtins.readDir ./packages;
      packageNames = builtins.filter
        (name:
          packageEntries.${name} == "directory"
          && ((builtins.readDir (./packages + "/${name}"))."package.nix" or null) == "regular")
        (builtins.attrNames packageEntries);
      packagesFor = system:
        let pkgs = import nixpkgs { inherit system; };
        in builtins.listToAttrs (map
          (name: {
            inherit name;
            value = builtins.addErrorContext "while evaluating custom package packages/${name}/package.nix"
              (let package = pkgs.callPackage (./packages + "/${name}/package.nix") { };
               in if nixpkgs.lib.isDerivation package then package
               else throw "packages/${name}/package.nix must return a Nix derivation");
          })
          packageNames);
    in {
      packages = forAllSystems packagesFor;
    };
}
