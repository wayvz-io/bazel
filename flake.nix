{
  description = "Native Bazel, built with Community or Oracle GraalVM";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/5e2305d577ca00acbba631b05cb1094d172b29f3";
  inputs.bcr = {
    url = "github:bazelbuild/bazel-central-registry/17afeb925dacab6ad4122744e23beda11b848fef";
    flake = false;
  };

  outputs =
    {
      self,
      nixpkgs,
      bcr,
    }:
    let
      system = "x86_64-linux";
      overlay =
        final: prev:
        import ./nix/packages.nix {
          pkgs = final;
          src = self;
          registry = bcr;
          nixpkgsPath = nixpkgs;
        };
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ overlay ];
      };
    in
    {
      overlays.default = overlay;
      packages.${system} = {
        inherit (pkgs) nBazel-community nBazel-oracle;
        default = pkgs.nBazel-community;
        bootstrap = pkgs.native-bazel-bootstrap;
      };
      checks.${system} = {
        community = pkgs.nBazel-community.tests.smoke;
        oracle = pkgs.nBazel-oracle.tests.smoke;
      };
      formatter.${system} = pkgs.nixfmt;
    };
}
