{
  lib,
  pkgs,
  runCommand,
  bash,
  python3,
  zip,
  unzip,
  zlib,
  src,
  registry,
  nixpkgsPath,
  bootstrap,
  version,
  edition,
  graalvm,
  gc,
  java,
}:
let
  # Bazel's embedded MODULE.tools selects a different Swift version from this source tree.
  smokeArchives = map (
    module:
    let
      metadata = builtins.fromJSON (builtins.readFile (registry + "/modules/${module}/source.json"));
    in
    pkgs.fetchurl {
      url = metadata.url;
      hash = metadata.integrity;
    }
  ) [ "rules_swift/3.1.2" ];
  smokeRepositoryCache = runCommand "native-bazel-smoke-repository-cache" { } ''
    mkdir -p $out
    ${pkgs.lndir}/bin/lndir -silent ${package.passthru.bazelRepoCache}/repo_cache $out
    for archive in ${lib.escapeShellArgs smokeArchives}; do
      hash=$(sha256sum "$archive" | cut -d ' ' -f 1)
      mkdir -p "$out/content_addressable/sha256/$hash"
      ln -sf "$archive" "$out/content_addressable/sha256/$hash/file"
    done
  '';
  # Exclude packaging changes from the dependency-fetch input.
  source = lib.cleanSourceWith {
    inherit src;
    filter =
      path: type:
      let
        relative = lib.removePrefix (toString src + "/") (toString path);
      in
      !(
        relative == "nix"
        || lib.hasPrefix "nix/" relative
        || builtins.elem relative [
          "flake.nix"
          "flake.lock"
        ]
        || lib.hasPrefix ".git" relative
        || lib.hasPrefix ".jj" relative
      );
  };
  preparedSource =
    runCommand "native-bazel-${version}-${edition}-source" { nativeBuildInputs = [ pkgs.patch ]; }
      ''
        cp -r ${source} $out
        chmod -R u+w $out
        cd $out
        ${lib.concatMapStringsSep "\n" (patch: "patch -p1 < ${patch}") (
          lib.filter (patch: !(lib.hasSuffix "-bazel_rc.patch" (toString patch))) bootstrap.patches
        )}
        ${python3}/bin/python3 ${./portable-test-shells.py} "$out"
        cat ${
          pkgs.replaceVars ./rules-python-shebang.patch { python = "${python3}/bin/python3"; }
        } >> third_party/rules_python.patch
        substituteInPlace $out/src/BUILD \
        --replace-fail 'gc = "G1"' 'gc = "${gc}"' \
        --replace-fail 'parallelism = 6,' 'parallelism = 6, use_bundle = False, include_management_library = ${
          if edition == "oracle" then "True" else "False"
        },' \
        --replace-fail ':embedded_tools_jdk_allmodules.zip' ':embedded_tools_nojdk.zip' \
        --replace-fail ':install_base_key-file_jdk_allmodules' ':install_base_key-file_nojdk'
      '';
  graalRepo = runCommand "graalvm-${edition}-bazel-repository" { } ''
    mkdir -p $out
    for entry in ${graalvm}/*; do ln -s "$entry" "$out/$(basename "$entry")"; done
    cat > $out/BUILD.bazel <<'BUILD'
    package(default_visibility = ["//visibility:public"])
    exports_files(glob(["**/*"]))
    filegroup(name = "files", srcs = glob(["**/*"]))
    BUILD
    touch $out/REPO.bazel
  '';
  buildBazel = pkgs.callPackage (
    nixpkgsPath + "/pkgs/by-name/ba/bazel_9/build-support/bazelPackage.nix"
  ) { };
  package = buildBazel {
    name = "native-bazel-${edition}";
    inherit version registry;
    src = preparedSource;
    bazel = bootstrap;
    serverJavabase = java;
    targets = [ "//src:bazel-bin_native" ];
    nativeBuildInputs = [
      python3
      zip
      unzip
    ];
    buildInputs = [
      zlib
      pkgs.stdenv.cc.cc.lib
    ];
    env = {
      JAVA_HOME = java;
      USE_BAZEL_VERSION = version;
      SOURCE_DATE_EPOCH = "1";
    };
    startupArgs = [ "--host_jvm_args=-Xmx4g" ];
    commandArgs = [
      "--override_repository=graalvm_25_3_4_1_linux_x64=${graalRepo}"
      "--java_runtime_version=local_jdk_25"
      "--tool_java_runtime_version=local_jdk_25"
      "--extra_toolchains=@@rules_java++toolchains+local_jdk//:all"
      "--lockfile_mode=off"
      "--stamp"
      # Feature detection and extension lock digests must match the upstream release.
      # The Nix output name identifies the runtime edition.
      "--embed_label=${version}"
      "--workspace_status_command=${pkgs.writeShellScript "native-bazel-build-status" ''
        printf 'BUILD_USER nix\nBUILD_HOST nix\n'
      ''}"
      "--jobs=6"
      "--local_resources=memory=16000"
    ];
    bazelRepoCacheFOD = {
      outputHash = "sha256-8qerxEoCWOt/Lozd0ld4Q3ZeNQvU0HwN5JBzYcitSY4=";
      outputHashAlgo = "sha256";
    };
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin $out/share/licenses/native-bazel $out/nix-support
      cp bazel-bin/src/bazel_native $out/bin/nbazel
      cp LICENSE $out/share/licenses/native-bazel/Bazel-LICENSE
      cp -rL ${graalvm}/legal $out/share/licenses/native-bazel/graalvm
      chmod -R u+w $out/share/licenses/native-bazel/graalvm
      (
        cd ${graalvm}
        find -L . -path ./legal -prune -o -type f \
          \( -iname '*license*' -o -iname '*notice*' -o -iname '*copyright*' \) -print0 \
          | while IFS= read -r -d $'\0' notice; do
              install -Dm644 "$notice" "$out/share/licenses/native-bazel/graalvm/$notice"
            done
      )
      # Nix cannot see library references inside the launcher's appended ZIP.
      ${python3}/bin/python3 - "$out/bin/nbazel" <<'PYTHON'
      import sys
      import zipfile
      with zipfile.ZipFile(sys.argv[1]) as archive:
          names = archive.namelist()
          assert "A-server-native" in names, "native server missing"
          assert "A-server.jar" not in names, "unexpected JVM server"
          assert not any(name.startswith("embedded_tools/jdk/") for name in names), "unexpected embedded JDK"
      PYTHON
      mkdir archive
      ${python3}/bin/python3 -m zipfile -e $out/bin/nbazel archive
      grep -rhoEa '/nix/store/[a-z0-9]{32}-[A-Za-z0-9+._?=-]+' archive \
        | sort -u > $out/nix-support/depends
      runHook postInstall
    '';
  };
  builtPackage = package.overrideAttrs (old: {
    nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.autoPatchelfHook ];
    buildInputs = old.buildInputs ++ [ pkgs.libxcrypt-legacy ];
    # Patch fetched build tools, but never patch the final launcher with its appended ZIP.
    dontAutoPatchelf = true;
    buildPhase = ''
      runHook preBuild
      export HOME=$(mktemp -d)
      bazel=( ${bootstrap}/bin/bazel --server_javabase=${java} --batch ${lib.escapeShellArgs package.startupArgs} )
      args=( --registry=file://${registry} --repository_cache="$PWD/repo_cache" --repo_contents_cache= ${lib.escapeShellArgs package.commandArgs} )
      "''${bazel[@]}" fetch "''${args[@]}" ${lib.escapeShellArgs package.targets}
      output_base=$("''${bazel[@]}" info output_base)
      while IFS= read -r -d $'\0' repository; do
        chmod -R u+w "$repository"
        autoPatchelf "$repository"
      done < <(find "$output_base/external" -mindepth 1 -maxdepth 1 -type d \
        \( -name '*remote_java_tools_linux' -o -name '*python_*x86_64-unknown-linux-gnu' \) -print0)
      "''${bazel[@]}" build "''${args[@]}" ${lib.escapeShellArgs package.targets}
      runHook postBuild
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      "$out/bin/nbazel" --ignore_all_rc_files --batch version
      runHook postInstallCheck
    '';
    passthru = package.passthru // {
      toolchain = graalvm;
      graalRepository = graalRepo;
      inherit smokeRepositoryCache;
      inherit edition;
      tests.smoke = runCommand "native-bazel-${edition}-smoke" { } ''
        mkdir repo_cache
        ${pkgs.lndir}/bin/lndir -silent ${smokeRepositoryCache} repo_cache
        ${bash}/bin/bash ${./smoke.sh} ${nativePackage}/bin/nbazel ${registry} "$PWD/repo_cache"
        ${bash}/bin/bash ${./heap-pressure-smoke.sh} ${nativePackage}/bin/nbazel ${registry} "$PWD/repo_cache"
        touch $out
      '';
    };
    dontStrip = true;
    meta = {
      description = "Bazel ${version} compiled with ${edition} GraalVM Native Image";
      platforms = [ "x86_64-linux" ];
      mainProgram = "nbazel";
      license =
        if edition == "oracle" then
          lib.licenses.unfree
        else
          [ lib.licenses.asl20 ] ++ lib.toList graalvm.meta.license;
    };
  });
  nativePackage =
    runCommand "native-bazel-${edition}"
      {
        inherit (builtPackage) version meta;
        passthru = builtPackage.passthru // {
          untrimmed = builtPackage;
        };
        # Do not rewrite the launcher ELF after appending its ZIP payload.
        dontFixup = true;
    disallowedRequisites = [
          graalvm
          pkgs.stdenv.cc.cc
          builtPackage
        ];
      }
      ''
        mkdir -p $out/bin $out/nix-support
        cp -r ${builtPackage}/share $out/share
        ${python3}/bin/python3 ${./trim-runtime.py} \
          ${builtPackage}/bin/nbazel $out/bin/nbazel \
          ${pkgs.stdenv.cc.cc} ${graalvm} \
          ${pkgs.patchelf}/bin/patchelf ${pkgs.removeReferencesTo}/bin/remove-references-to \
          > $out/nix-support/depends
        $out/bin/nbazel --ignore_all_rc_files --output_user_root="$TMPDIR/bazel-version" --batch version
      '';
in
nativePackage
