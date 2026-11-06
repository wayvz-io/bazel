#!/usr/bin/env bash
set -euo pipefail

nbazel=$1
registry=$2
repository_cache=$3
root=$(mktemp -d)
mkdir "$root/workspace"
cd "$root/workspace"
printf 'module(name = "heap_pressure_smoke")\nbazel_dep(name = "platforms", version = "1.0.0")\n' > MODULE.bazel
for name in first disabled next; do
    printf 'genrule(name = "%s", outs = ["%s.txt"], cmd = "%s 8; echo passed > $@")\n' \
        "$name" "$name" "$(command -v sleep)" >> BUILD.bazel
done
export BAZEL_NATIVE_IMAGE_SERVER_XMX=256m
base=("$nbazel" --ignore_all_rc_files --output_user_root="$root/user" --output_base="$root/output")
trap 'timeout 60 "${base[@]}" shutdown' EXIT
install_base=$("${base[@]}" --batch info install_base)
flags=(--registry="file://$registry" --repository_cache="$repository_cache"
    --repo_env=BAZEL_HTTP_RULES_URLS_AS_DEFAULT_CANONICAL_ID=0
    --override_repository="platforms=$install_base/platforms" --lockfile_mode=off
    --spawn_strategy=local)
# A zero threshold exercises lifecycle behavior without depending on heap occupancy.
enabled=(--experimental_native_heap_pressure_monitor --experimental_native_heap_pressure_threshold=0
    --experimental_native_heap_pressure_max_drops=2)
log="$root/output/java.log"
pattern='Dropped temporary caches after sustained sampled heap pressure'
"${base[@]}" build "${flags[@]}" "${enabled[@]}" //:first
test "$(grep -c "$pattern" "$log")" = 1
# Wait beyond the 30-second cooldown with a remaining drop available. A leaked
# monitor would clear caches while the server is idle and fail this assertion.
sleep 35
test "$(grep -c "$pattern" "$log")" = 1
"${base[@]}" build "${flags[@]}" //:disabled
test "$(grep -c "$pattern" "$log")" = 1
"${base[@]}" build "${flags[@]}" "${enabled[@]}" //:next
test "$(grep -c "$pattern" "$log")" = 2
