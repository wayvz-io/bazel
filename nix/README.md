# Native Bazel Nix packages

This flake is under development. The Community executable passes the runtime smoke checks, and the memory-pressure regression tests pass. Clean Nix builds and flake checks for both variants are still pending. Do not replace a CI runner's Bazel with these packages until both variants pass the release checks below.

The flake exposes two Linux x86-64 packages from the same source tree and build recipe.

| Output | Native Image compiler | Garbage collector | Nix policy |
| --- | --- | --- | --- |
| `nBazel-community` | Community, pinned by `flake.lock` | Serial | Free |
| `nBazel-oracle` | Oracle 25.0.4.1 | G1 | Unfree opt-in |

Both packages install `bin/nbazel`. Community is the default flake output. The native server currently targets x86-64-v2. ARM packages are not implemented. These packages omit the embedded JDK. Java build actions need an explicit Java toolchain, as they do with a `bazel_nojdk` distribution.

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

The pinned Native Image runtimes do not provide GC notifications used by Bazel's memory-pressure listener. Bazel warns at startup because heap-pressure-based cache trimming and GC-thrashing detection are unavailable. Set a native heap limit with `BAZEL_NATIVE_IMAGE_SERVER_XMX`, for example `BAZEL_NATIVE_IMAGE_SERVER_XMX=2g nbazel build //:target`, and measure peak memory before increasing job concurrency.

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

The current reference scan also retains GCC because an assertion in the native server embeds a GCC header path. Remove that diagnostic-only reference and recheck the runtime closure before publishing.

Check all outputs with Oracle evaluation explicitly enabled:

```sh
NIXPKGS_ALLOW_UNFREE=1 nix flake check --impure
```

The first milestone is two successful Nix builds and smoke checks. Rename the repository to `native-bazel`, add release automation, and roll out to CI after that milestone.
