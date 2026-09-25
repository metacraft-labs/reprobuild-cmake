{
  description = "Development environment for the Reprobuild CMake fork";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/devops-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      perSystem = { pkgs, ... }: {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [ pkgs.gnumake pkgs.pkg-config ];
          # CMake's bootstrap also needs library/header discovery variables,
          # which installing a compiler executable alone does not provide.
          buildInputs = [ pkgs.openssl pkgs.libiconv ];
          # Bootstrap runs our CMake before the Nix CMake setup hook exists.
          # Its find_path() calls therefore need the package prefixes explicitly.
          CMAKE_PREFIX_PATH = pkgs.lib.makeSearchPath "" [
            (pkgs.lib.getDev pkgs.openssl)
            (pkgs.lib.getDev pkgs.libiconv)
          ];
        };
      };
    };
}
