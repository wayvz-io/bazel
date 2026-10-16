{
  pkgs,
  src,
  registry,
  nixpkgsPath,
}:
let
  inherit (pkgs) lib;
  version = "9.3.0";
  bootstrap = (pkgs.bazel_9.override { inherit version; }).overrideAttrs (old: {
    src = pkgs.runCommand "bazel-${version}-bootstrap-source" { nativeBuildInputs = [ pkgs.unzip ]; } ''
      mkdir -p $out
      unzip -q ${
        pkgs.fetchurl {
          url = "https://github.com/bazelbuild/bazel/releases/download/${version}/bazel-${version}-dist.zip";
          hash = "sha256-JXRAStotbbvaWLAqqIsXxHl2N5DhjLh1B4xAyEnPZxA=";
        }
      } -d $out
    '';
    buildPhase =
      builtins.replaceStrings [ "--curses=no" ] [ "--curses=no --jobs=6 --local_resources=memory=16000" ]
        old.buildPhase;
    patches = map (
      patch:
      if
        builtins.elem (builtins.baseNameOf (toString patch)) [
          "apple_cc_toolchain.patch"
          "deps_patches.patch"
        ]
      then
        pkgs.runCommand (builtins.baseNameOf (toString patch)) { } ''
          sed 's/1\.24\.5/2.5.2/g' ${patch} > $out
        ''
      else if lib.hasSuffix "-usr_bin_env.patch" (toString patch) then
        pkgs.runCommand "usr_bin_env-9.3.patch" { } ''
          sed 's|^-#!/bin/bash$|-#!/usr/bin/env bash|' ${patch} > $out
        ''
      else
        patch
    ) old.patches;
  });
  community = pkgs.graalvmPackages.graalvm-ce;
  oracle = pkgs.graalvmPackages.buildGraalvm {
    pname = "graalvm-oracle";
    version = "25.0.4.1";
    src = pkgs.fetchurl {
      url = "https://gds.oracle.com/download/graal/25i3/archive/graalvm-jdk-25i3-25.0.4.1_linux-x64_bin.tar.gz";
      sha256 = "814deac144a912035c4e824e05fa06a2e0c83821f0fb9d1084bc916e5eeef247";
    };
    autoPatchelfIgnoreMissingDeps = [ "libonnxruntime.so.1" ];
    meta = {
      license = lib.licenses.unfree;
      platforms = [ "x86_64-linux" ];
    };
  };
  build =
    edition: graalvm: gc:
    pkgs.callPackage ./native-bazel.nix {
      inherit
        src
        registry
        nixpkgsPath
        bootstrap
        version
        edition
        graalvm
        gc
        ;
      java = community;
    };
in
{
  native-bazel-bootstrap = bootstrap;
  nBazel-community = build "community" community "serial";
  nBazel-oracle = build "oracle" oracle "G1";
}
