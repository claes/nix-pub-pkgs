# Implementation plan

1. **Build the Nix foundation first.** Add an independently pinned flake, automatic discovery of `packages/<name>/package.nix`, and a customized GNU Hello derivation. Validate flake evaluation, build Hello, run it, check its metadata, and confirm its derivation and output differ from nixpkgs Hello.
2. **Add local build automation.** Implement a build-all script that discovers packages from JSON flake outputs, builds every output, writes all resulting store paths to a manifest, and handles empty sets and failures. Exercise package addition/removal and output handling locally.
3. **Add publishing and CI.** Once local builds pass, implement signed native Nix S3 publishing and the GitHub Actions validation/build/publish workflow. Keep publishing secrets unavailable to pull requests and restrict publication to main.
4. **Document and configure operations.** Write development, AWS, and NixOS integration guides; then provision AWS and configure GitHub only after the build and publish code is ready. Verify uploaded metadata, signatures, public reads, and substitution where credentials and infrastructure are available.

The Nix implementation and its local build acceptance checks are the gate before GitHub Actions or S3 work begins.

## Progress

Step 1 is complete. Local validation passed: `nix flake show`, `nix flake check`,
`nix build .#hello`, the `Hello, world!` greeting, and the exact build-info
contents. Both the derivation and output paths differ from standard Hello evaluated
with the same locked nixpkgs input. Step 2 is next; GitHub Actions and S3 work have
not started.

## Package layout revision

Each package lives in `packages/<name>/package.nix` and exports the directory name.
Hello is now built with `nix build .#hello`. Loose files and directories without a
regular `package.nix` are ignored. The existing custom metadata path remains
`share/hello-custom/build-info.txt`.

The layout revision passed `nix flake show`, `nix flake check`, and
`nix build .#hello`. The greeting and exact metadata contents were verified, and
both derivation and output paths differ from standard Hello. Temporary-copy tests
passed for package addition/removal, hyphenated names, ignored loose files and
directories without `package.nix`, and an invalid derivation's error message.

## Standalone Hello derivation

Define Hello directly using `stdenv.mkDerivation` and a fixed-hash upstream
source archive. Run its upstream tests and retain the custom metadata. No
`pkgs.hello` dependency or overrides are used in the package definition.

Standalone derivation validation passed: `nix flake check`, `nix build .#hello`,
the usual greeting, and exact custom metadata contents. The upstream suite reports
6 passed, 1 skipped, 0 failed, and 0 errors. The new output is
`/nix/store/znw97y72lmdl5bxdykh59f0if15w3kzr-hello-2.12.3`.
