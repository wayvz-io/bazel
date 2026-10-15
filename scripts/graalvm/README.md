# Build native Bazel 9.3.0

This branch ports [Bazel PR #30282](https://github.com/bazelbuild/bazel/pull/30282),
at `a9609f07ecb644497fb01f63596511062fc58204`, onto the unmodified `9.3.0` tag,
`e89755babf3e941bc1e9d8120b1cd48854ab9dfa`.
It also includes the prerequisite changes from PRs #30284, #30285, and #30286.
The original native-image work is by Son Luong Ng and its upstream contributors.

The native server targets Linux x86-64-v2 and uses Oracle GraalVM 25.3.4.1.
Bazel 9.3.0 uses older JNI classes than the original patch. This port registers
those classes and retains 9.3.0's existing Wasm interpreter. The existing
GraalVM 21 toolchains for other targets remain unchanged.

## Build in Ubuntu

Run these commands from the repository root. The container needs network access
to download Bazel dependencies. Allocate at least 24 GiB of memory.

```sh
podman build -t bazel-graalvm-builder -f scripts/graalvm/Containerfile .
podman run -d --name bazel-graalvm-build --userns=keep-id:uid=0,gid=0 \
    -v "$PWD:/workspace" -w /workspace bazel-graalvm-builder sleep infinity
podman exec bazel-graalvm-build bazel --host_jvm_args=-Xmx8g build \
    //src:bazel-bin_native --jobs=6 --local_resources=memory=16000 \
    --stamp --embed_label=9.3.0-graalvm --lockfile_mode=update
```

Keep the container for subsequent builds to reuse its Bazel cache. A host-specific
`user.bazelrc` can interfere with the container build; omit that file in this checkout.

## Run the native binary

```sh
podman exec bazel-graalvm-build /workspace/bazel-bin/src/bazel_native \
    --output_user_root=/tmp/bazel-native-smoke version
```

The output symlinks point into the build container. Copy the binary out with
`podman cp` if you need a standalone artifact. The binary requires a compatible
Linux dynamic loader and C library.

## Run native integration tests

```sh
podman exec bazel-graalvm-build bazel --host_jvm_args=-Xmx8g test \
    --config=native-image-tests --jobs=6 --local_test_jobs=2 \
    --test_output=errors --lockfile_mode=error \
    --stamp --embed_label=9.3.0-graalvm \
    //src/test/shell/integration:client_test \
    //src/test/shell/integration:startup_options_test \
    //src/test/shell/integration:unicode_test
```

Broader suites are available at
`//src/test/shell/integration:native_image_core_tests` and
`//src/test/shell/bazel/remote:native_image_core_tests`.

## Update the port

Keep the release base separate from the native-image changes. On each upgrade,
check JNI class names, reflection configuration, runtime initialization, startup
arguments, packaging, and the integration test target locations. A clean patch
application does not prove native runtime compatibility.

The PGO benchmark scripts came from upstream. Their historical commit workloads
require a checkout containing the relevant history; a shallow release checkout
is not sufficient.
