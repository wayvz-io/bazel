# Native Bazel Nix packages

Both variants pass clean sandboxed Nix builds, offline flake smoke checks, and heap-monitor lifecycle checks. Native and RBE validation is complete for the experimental heap-pressure fallback; it remains off by default based on the trial results below. CI adoption remains pending the release checks below.

The flake exposes two Linux x86-64 packages from the same source tree and build recipe.

| Output | Native Image compiler | Garbage collector | Nix policy |
| --- | --- | --- | --- |
| `nBazel-community` | Community, pinned by `flake.lock` | Serial | Free |
| `nBazel-oracle` | Oracle 25.0.4.1 | G1 | Unfree opt-in |

Both packages install `bin/nbazel`. Community is the default flake output. The native server currently targets x86-64-v2. ARM packages are not implemented. These packages omit the embedded JDK. Java build actions need an explicit Java toolchain, as they do with a `bazel_nojdk` distribution.

Both editions report the upstream Bazel version without an edition suffix. The `bazel_features` module embeds that string in generated Starlark, so suffixes would change extension lock digests when switching runtimes. Use the flake output name to identify the edition.

## Build a variant

Community does not require unfree packages:

```sh
nix build .#nBazel-community
```

For Oracle, explicitly opt in:

```sh
NIXPKGS_ALLOW_UNFREE=1 nix build --impure .#nBazel-oracle
```

Consumers can also import `overlays.default` and configure their own `allowUnfreePredicate`. The flake never sets `allowUnfree = true` on their behalf.

The compiler distributions are pinned binary inputs. Bazel itself, including the stock bootstrap, is built from source. A fixed-output derivation fetches Bazel dependencies before the sandboxed package build. The dependency cache has a pinned SHA-256 hash. During the offline build, the recipe patches downloaded Java and Python tools to use Nix loader and library paths.

The pinned Native Image runtimes do not provide GC notifications used by Bazel's memory-pressure listener. Bazel warns at startup because GC-driven cache trimming and GC-thrashing detection are unavailable. Set a native heap limit with `BAZEL_NATIVE_IMAGE_SERVER_XMX`, for example `BAZEL_NATIVE_IMAGE_SERVER_XMX=2g nbazel build //:target`, and measure peak memory before increasing job concurrency.

### Configure remote action tools

Nix patches Bazel's default action `PATH` to use Nix tools. Remote workers must either contain those paths or receive an explicit `PATH` matching their image. For Bombora's current RBE worker image, use:

```text
build:remote --action_env=PATH=/bin:/usr/bin:/usr/local/bin
build:remote --host_action_env=PATH=/bin:/usr/bin:/usr/local/bin
build:remote --shell_executable=/bin/bash
```

Without these settings, npm lifecycle actions cannot find `bash`, and shell actions try to execute a Nix store path on the worker. The native runtime benchmark applies these settings to every variant, including stock JVM Bazel. Embedded test helpers start through `/bin/sh` and enter Bash, so the same helpers work inside Nix sandboxes and on the remote workers.

### Experimental heap-pressure fallback

`--experimental_native_heap_pressure_monitor` enables cache trimming based on sampled total heap usage when GC notifications are unavailable. The flag is off by default. It does not change the garbage collector or force collection.

The monitor samples once per second during a command. After three seconds at or above the threshold, it drops temporary Skyframe state and clears the syscall cache. Cleanup has a 30-second cooldown and a per-command limit. Command teardown stops the monitor and waits for an active cleanup to finish.

| Flag | Default | Meaning |
| --- | --- | --- |
| `--experimental_native_heap_pressure_threshold` | `85` | Used heap as a percentage of maximum heap, from 0 to 100 |
| `--experimental_native_heap_pressure_max_drops` | `3` | Maximum cleanup calls per command; zero disables cleanup |

Sampled usage includes uncollected garbage. It cannot establish the amount of live data after collection, so these samples do not feed GC-thrashing or GC-churning detection. Cleanup logs identify sampled pressure, and the internal `MemoryPressureStats.sampled_heap_drops` counter is separate from GC-driven drops. This counter is not currently exported through BEP.

Runtime probes of the pinned compilers found usable `Runtime` and `MemoryMXBean` heap readings in both editions. Community recorded GC events in a JFR file, but the short probe did not deliver GC callbacks through its live recording stream. Oracle G1 exposed neither collector beans nor GC events in that probe. The shared fallback therefore uses heap samples.

### RBE trial results

The 2026-10-16 trial used Bombora commit `9663e67d41ba1f6738c5280b8d6a498b4047ba9f`. Two concurrent Bazel jobs shared a pod limited to four CPUs. Each job used 220 action slots, a warm repository cache, a warm RBE cache, and a fresh output base. Installation happened before measurement. BES was disabled and Bazel profiling was enabled.

The workload contained `//scheduler/core:scheduler_core_test`, `//deploy/server:cp_server_test`, `//web/bombora/app:unit_test`, and `//web/bombora/app:check`. All four targets passed in both jobs for these configurations, with sampled cleanup disabled:

| Runtime | Heap limit per server | Pair completion time | Sampled peak proportional process memory |
| --- | --- | --- | --- |
| Stock JVM Bazel 9.3.0 | 512 MiB | 79–85 seconds in two runs | 1.97–2.05 GiB |
| Community Serial, reporting 9.3.0 | 1 GiB | 59 seconds | 2.76 GiB |
| Oracle G1, reporting 9.3.0 | 512 MiB | 58 seconds | 1.54 GiB |

Proportional memory accounts for shared mapped pages without counting each page fully in both servers. Samples were taken every 0.5 seconds and summed across the pod's processes, including bb-clientd. They exclude unmapped filesystem cache and are not pod memory limits. The trial is a representative workload, not a full CI rollout.

Both native editions passed with the stock JVM lockfile and `--lockfile_mode=error`. No lockfile regeneration was needed after removing the edition suffixes.

At 512 MiB, the Oracle fallback performed one cleanup per job. Repeated runs did not show a consistent timing or peak-memory benefit. At 384 MiB, Oracle exhausted its heap with the fallback both off and on. Cleanup delayed the failure. Community also exhausted its heap at 512 MiB. The fallback remains off by default; heap sizing is the useful tuning control demonstrated by this trial.

## Runtime licenses

Each package retains Bazel's license and the compiler distribution's runtime legal notices. Oracle's Native Image runtime portions remain subject to the [GraalVM Free Terms and Conditions](https://www.oracle.com/downloads/licenses/graal-free-license.html). Marking the Nix package unfree does not change those terms.

Community runtime components carry their own licenses, including GPLv2 with the Classpath Exception. Before publishing the Community binary cache, include the corresponding runtime source or the applicable source offer. Verify that both distributions retain their required notices.

## Release process

Track stable Bazel minor and patch releases. Do not follow nightly builds. Keep one fork and one native patch series for both editions.

For each release:

1. Rebase the native patch series onto the upstream stable tag.
2. Update the Bazel version, bootstrap source hash, and any Nix compatibility patches.
3. Update compiler pins deliberately. Record compiler version and collector with benchmark results.
4. Refresh dependency hashes against the pinned registry, then build both outputs with sandboxing enabled.
5. Run the shared smoke checks, a representative Bombora build with RBE, and the paired concurrency benchmark. Check startup, repository evaluation, tests, server shutdown, memory, and cached actions.
6. Inspect runtime closures for accidental compiler dependencies and verify licenses before publishing both closures to the Garage-backed Nix cache.
7. Update Bombora's pinned input in a separate PR after validation.

The runtime packaging step removes compiler header references from the launcher and embedded helpers. Oracle's management library and its Java/JVM shared-library dependencies are packaged beside the native server with relative library paths. Each payload change gets a new install-base key. Nix rejects closures containing the compiler, GraalVM distribution, or untrimmed package.

The resulting runtime closures are approximately 469 MiB for Community and 517 MiB for Oracle, down from 749 MiB and 1.9 GiB. Runtime repackaging is a separate derivation, so changing it can reuse the validated native compilation.

Check all outputs with Oracle evaluation explicitly enabled:

```sh
NIXPKGS_ALLOW_UNFREE=1 nix flake check --impure
```

The package-build milestone has passed. Repository renaming, release automation, binary-cache publication, and CI rollout remain separate follow-up work after runtime validation.
