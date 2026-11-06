#!/usr/bin/env bash
set -euo pipefail

# Run as an offline flake check with the fetched dependency cache available.
nbazel=$1
registry=$2
repository_cache=$3
export BAZEL_NATIVE_IMAGE_SERVER_XMX=2g
unset JAVA_HOME JDK_HOME
export HOME
HOME=$(mktemp -d)
workspace=$(mktemp -d)
cd "$workspace"
printf 'module(name = "native_bazel_smoke")\nbazel_dep(name = "platforms", version = "1.0.0")\n' > MODULE.bazel
cat > BUILD.bazel <<'BUILD'
load(":smoke_test.bzl", "smoke_test")

genrule(
    name = "hello",
    outs = ["hello.txt"],
    cmd = "printf 'native-bazel smoke\\n' > $@",
)

smoke_test(name = "hello_test", data = ":hello")
BUILD
cat > smoke_test.bzl <<STARLARK
def _smoke_test_impl(ctx):
    executable = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        executable,
        "#!$(command -v bash)\nset -eu\ntest \"\$($(command -v cat) \"\${TEST_SRCDIR}/\${TEST_WORKSPACE}/hello.txt\")\" = 'native-bazel smoke'\n",
        is_executable = True,
    )
    return [DefaultInfo(executable = executable, runfiles = ctx.runfiles(files = [ctx.file.data]))]

smoke_test = rule(
    implementation = _smoke_test_impl,
    test = True,
    attrs = {"data": attr.label(allow_single_file = True)},
)
STARLARK
"$nbazel" --ignore_all_rc_files --batch version
install_base=$("$nbazel" --ignore_all_rc_files --batch info install_base)
test -d "$install_base/platforms"
common=(--registry="file://$registry" --repository_cache="$repository_cache" \
    --repo_env=BAZEL_HTTP_RULES_URLS_AS_DEFAULT_CANONICAL_ID=0 \
    --override_repository="platforms=$install_base/platforms" --lockfile_mode=off)
"$nbazel" --ignore_all_rc_files --batch query "${common[@]}" //:hello
"$nbazel" --ignore_all_rc_files --batch build "${common[@]}" \
    --spawn_strategy=local //:hello
test "$(cat bazel-bin/hello.txt)" = 'native-bazel smoke'
# Exercise the persistent server used by CI, including cached execution and shutdown.
"$nbazel" --ignore_all_rc_files build "${common[@]}" \
    --spawn_strategy=local //:hello
"$nbazel" --ignore_all_rc_files build "${common[@]}" \
    --spawn_strategy=local //:hello
"$nbazel" --ignore_all_rc_files test "${common[@]}" \
    --spawn_strategy=local --test_output=errors //:hello_test
timeout 60 "$nbazel" --ignore_all_rc_files shutdown
