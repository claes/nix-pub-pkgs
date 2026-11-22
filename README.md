# Custom Nix packages

An independent, pinned Nix flake for custom `x86_64-linux` packages. It currently
contains GNU Hello built from source with custom metadata, and the Peek terminal
file viewer.

Package definitions → automatic flake discovery → GitHub Actions builds → signed
AWS S3 binary cache → NixOS downloads over public regional HTTPS.

## Quick start

With Nix flakes, `nix-command`, Bash, and `jq` available:

```bash
nix flake show
nix build .#hello
./result/bin/hello
cat result/share/hello-custom/build-info.txt
nix build .#peek --out-link result-peek
./result-peek/bin/peek --version
./scripts/build-all.sh
```

The build-all script builds every package and every output, printing store paths
and saving them in `.build/store-paths`. Local builds do not publish.

## Layout

```text
flake.nix / flake.lock        Independent nixpkgs pin and discovery
packages/<name>/package.nix   One derivation per package directory
scripts/build-all.sh          Build and record all outputs
scripts/publish-cache.sh      Sign and upload runtime closures to AWS S3
scripts/verify-cache.sh       Check S3 objects and signed closure
scripts/run-cached-hello.sh   Build Hello using the cache, then run it
.github/workflows/build.yml   PR validation and trusted-master publication
tests/                       Local build and signed-cache integration tests
docs/setup.md                Complete ordered setup and operations guide
```

Add `packages/my-tool/package.nix` and stage it in Git. Discovery exports
`packages.x86_64-linux.my-tool` using `pkgs.callPackage`; adding a package requires
no flake registry or workflow changes.

## CI and consumption

PRs validate and build without publishing credentials. Pushes to `master` and manual
runs on `master` validate, build, then publish with a private Nix signing key and
dedicated IAM access keys. Other manual refs build only. Configure the protected
`nix-cache` GitHub environment with `master` allowed before publishing.

The S3 bucket stores standard `nix-cache-info`, narinfo metadata, and NAR objects.
Consumers add this repository as a flake input and trust its signing public key,
then download from `https://BUCKET_NAME.s3.REGION.amazonaws.com` without AWS
credentials. Keep the repository's independent nixpkgs pin to obtain cache hits.

Follow the [complete step-by-step setup guide](docs/setup.md), from local builds
through AWS/GitHub configuration to NixOS installation and verification.

- [Implementation progress and validation limits](IMPLEMENTATION-PLAN.md)

Local builds and signed file-cache tests have passed. Live AWS publication and
GitHub execution remain pending infrastructure, credentials, and a GitHub remote.
