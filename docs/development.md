# Local development

NixOS includes Nix. On other Linux systems, install Nix using the
[official installation instructions](https://nixos.org/download/).

Use Nix with `flakes` and `nix-command` enabled, plus Bash and `jq` on PATH.
For a local Nix installation, add `experimental-features = nix-command flakes`
to `~/.config/nix/nix.conf`. On NixOS, set
`nix.settings.experimental-features = [ "nix-command" "flakes" ];` in a module.

To get the local script tools from the pinned nixpkgs, run
`nix shell --inputs-from . nixpkgs#jq nixpkgs#shellcheck nixpkgs#python3`
from the repository root.

## Build packages

```bash
nix flake show
nix flake check
nix build .#hello
./result/bin/hello
cat result/share/hello-custom/build-info.txt
nix build .#peek --out-link result-peek
./result-peek/bin/peek --version
./scripts/build-all.sh
```

The build-all script evaluates package names, builds all packages and every output
in one Nix invocation, and prints deduplicated store paths to stdout. Diagnostics
go to stderr. The same paths are saved in `.build/store-paths` for later publishing.
Building requires no AWS credentials and does not publish anything.

The script works from any working directory. `SYSTEM` defaults to `x86_64-linux`;
unsupported systems fail. `OUTPUTS_FILE` overrides the manifest path; relative paths
are resolved from the repository root. Each run removes the previous manifest
before evaluation, then replaces it atomically after a successful build. An empty
package set succeeds with an empty manifest. Run only one build-all process per
manifest path. The manifest is not a garbage-collection root; rebuild before
publishing if store garbage collection has run.

## Add a package

Create `packages/my-tool/package.nix` returning a derivation accepted by
`pkgs.callPackage`. The directory name becomes the flake package name. Supporting
sources and patches can live alongside it. Loose files and directories without a
regular `package.nix` are ignored.

Stage new package files with `git add packages/my-tool` so Git-backed flake
evaluation can see them. Run `nix flake show`, `nix build .#my-tool`, and
`./scripts/build-all.sh`, then commit. Package discovery requires no changes to
the flake or CI configuration.

## Check build automation

```bash
for script in scripts/*.sh; do bash -n "$script"; done
shellcheck scripts/*.sh
python3 tests/build-all.py
python3 tests/publish-cache.py
nix run --inputs-from . nixpkgs#actionlint -- .github/workflows/build.yml
```

The integration tests use temporary copies of the flake, the pinned nixpkgs,
and small real Nix builds. They need Python 3 and daemon/network access as needed
by Nix. Test packages do not remain in this repository.

Update the independent nixpkgs pin with `nix flake update nixpkgs`, then rerun
validation and builds. Dependency changes can change derivation and output paths.
Commit `flake.lock` with the update.

## Publish manually

Follow [AWS and GitHub setup](aws-setup.md) first. Normal builds never publish.
For an authorized manual upload, use an interactive shell with tracing disabled:

```bash
set +x
read -r -p 'AWS access key ID: ' AWS_ACCESS_KEY_ID
read -r -s -p 'AWS secret access key: ' AWS_SECRET_ACCESS_KEY
printf '\n'
read -r -p 'Region: ' AWS_REGION
read -r -p 'Bucket name: ' S3_BUCKET
NIX_CACHE_SIGNING_KEY=$(cat /secure/path/cache-private-key.pem)
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION S3_BUCKET NIX_CACHE_SIGNING_KEY
./scripts/build-all.sh && ./scripts/publish-cache.sh
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY NIX_CACHE_SIGNING_KEY
```

Do not put credentials into committed scripts, command arguments, or shell history.
The private signing key is supplied as contents, not a filename. Publishing reads
`OUTPUTS_FILE` with the same default as building, signs entries with a private
0600 temporary file, deletes the file on exit, and uploads runtime closures.
Repeated copies skip paths already present. AWS CLI is not needed for publishing.

The publishing tests use generated test keys, a shim translating the copy target
to a temporary local file cache, and real Nix copy/signature verification in an
isolated store. They exercise secret handling and closure export without AWS.
The production script accepts only AWS bucket/region settings, with no alternative
backend configuration.
