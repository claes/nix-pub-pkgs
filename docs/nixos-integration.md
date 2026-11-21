# Consume packages from a separate NixOS flake

## Add the input and module

Add `my-packages` to your existing flake's `inputs`, include it in the `outputs`
argument, and refer to its package output in a normal NixOS module. Keep your
existing host configuration and hardware imports. The example below assumes your
existing host module is `./configuration.nix`; replace that path and `my-host` with
your own. It is a complete flake structure, not a replacement host configuration.

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    my-packages.url = "github:YOUR_USER/nix-packages";
  };

  outputs = { nixpkgs, my-packages, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        ({ ... }: {
          environment.systemPackages = [
            my-packages.packages.x86_64-linux.hello
            my-packages.packages.x86_64-linux.peek
          ];

          nix.settings = {
            substituters = [
              "https://cache.nixos.org"
              "https://BUCKET_NAME.s3.REGION.amazonaws.com?priority=50"
            ];
            trusted-public-keys = [
              "my-nix-cache-1:PUBLIC_KEY"
            ];
          };
        })
      ];
    };
  };
}
```

Replace the GitHub owner/repository, bucket, region, and public key. Paste the
**complete** public-key line generated in [AWS setup](aws-setup.md), including its
key name. Never use the private signing key on consumers. Normal NixOS module
list merging retains the official cache key; avoid forcing a replacement of your
existing trusted keys or cache settings.

For an existing module in a different file, you can also pass `my-packages` through
`specialArgs` in `nixosSystem` and accept `{ my-packages, ... }` in that module.
The inline example keeps the input directly in scope.

The regional endpoint is for anonymous HTTPS object downloads, not S3 website
hosting. For example, `https://my-nix-binary-cache.s3.eu-north-1.amazonaws.com`.
Consumers need no AWS SDK, IAM keys, or S3-specific Nix support.

Keep the official NixOS cache enabled. Nix uses substituter priorities and
availability to choose downloads, and may query both caches. Standard dependencies
normally come from `cache.nixos.org`; custom paths can come from S3. The example
sets the S3 substituter priority to 50, below the official cache's usual priority
of 40 (lower numbers are preferred). This query parameter is a Nix client setting;
the underlying download endpoint remains the same regional HTTPS bucket URL.
See [HTTP cache settings](https://nix.dev/manual/nix/2.34/store/types/http-binary-cache-store). If a substitute
is absent, Nix can build locally when sources and dependencies are available.

## Lock files and installation

The NixOS flake's `flake.lock` pins a particular revision of this package repository.
The package repository's own lock independently pins nixpkgs; CI builds that
revision. Do not add `my-packages.inputs.nixpkgs.follows = "nixpkgs"` by default or
otherwise override that input. A different dependency graph can change derivation
and store paths, making uploaded substitutes unusable for the requested build.
Updating the NixOS flake's own nixpkgs does not require changing the package pin.

After adding the input, update only that input, review and commit your lock file:

```bash
nix flake update my-packages
sudo nixos-rebuild switch --flake .#my-host
hello
peek --version
```

Enable the cache settings on the machine before expecting substitution. On the
first rebuild, the running daemon still has the previous cache configuration;
you can first apply the cache module without the new packages, then add them and
rebuild. Do not interpret a local first build as proof the cache is broken.

Inspect the custom Hello output from the consuming flake directory:

```bash
hello_path=$(nix eval --impure --raw --expr \
  '(builtins.getFlake (toString ./.)).inputs.my-packages.packages.x86_64-linux.hello.outPath')
printf '%s\n' "$hello_path"
cat "$hello_path/share/hello-custom/build-info.txt"
nix path-info "$hello_path"
```

This evaluates exactly the package input locked by your NixOS flake. The metadata
is in that package output; do not assume a particular `/run/current-system/sw/share`
layout. The package is intentionally different from standard nixpkgs Hello.

## Release and update process

1. Change a package definition in the package repository and push to trusted `main`.
2. Wait for CI to build and publish successfully.
3. In the separate NixOS repository, run `nix flake update my-packages`.
4. Review and commit its lock file, rebuild the host, and inspect substitution logs.

New upstream commits are not consumed automatically: your NixOS lock file remains
pinned until explicitly updated. Use the corresponding package repository commit
when comparing CI and consumer output paths.

## Verify availability and downloads

From the consuming flake directory, using the `hello_path` evaluated above:

```bash
cache='https://BUCKET_NAME.s3.REGION.amazonaws.com'
public_key='my-nix-cache-1:REPLACE_WITH_FULL_PUBLIC_KEY'
curl -f "$cache/nix-cache-info"
nix path-info --store "$cache" --recursive --sigs "$hello_path"
nix build --dry-run --no-link --impure --expr \
  '(builtins.getFlake (toString ./.)).inputs.my-packages.packages.x86_64-linux.hello'
```

The cache query checks metadata and runtime references; it does not by itself prove
that the NAR bodies download or that signatures are accepted. The dry run shows
planned downloads/builds using the current daemon configuration. If the path is
already present locally, no download is planned.

For a stronger test, use a new isolated store without deleting active paths:

```bash
verify_root=$(mktemp -d)
nix copy --from "$cache" --to "local?root=$verify_root" \
  --option trusted-public-keys "$public_key" "$hello_path"
nix store verify --store "local?root=$verify_root" --all --sigs-needed 1 \
  --option trusted-public-keys "$public_key"
```

This downloads the runtime closure and checks signatures in an empty temporary
store. Its physical files are under `$verify_root/nix/store`, but logical paths
remain `/nix/store`, matching published artifacts. Do not execute those physical
paths directly: the program's references still use the logical store prefix.
Inspect and remove the temporary directory afterward. No production store path
needs to be deleted. See [Nix local store semantics](https://nix.dev/manual/nix/2.34/store/types/local-store).

## Troubleshooting

### Wrong URL, region, 403, or 404

```bash
curl -v "$cache/nix-cache-info"
store_hash=${hello_path##*/}
store_hash=${store_hash%%-*}
curl -f "$cache/$store_hash.narinfo"
```

Use the bucket's actual region and regional REST HTTPS endpoint, not a website
endpoint. Redirects can indicate the wrong region. A 403 can mean public-read
policy or Block Public Access restrictions, or a nonexistent object when anonymous
listing is denied. A 404 usually indicates an absent object; check the workflow
and expected hash. Have the bucket operator use authenticated `head-object` as
shown in [AWS setup](aws-setup.md). Do not solve anonymous reads by adding AWS
credentials to the consumer.

If `nix-cache-info` is missing, check that publication finished and the bucket URL
is correct before diagnosing package signatures.

### Missing or mismatched signatures

```bash
curl -f "$cache/$store_hash.narinfo" | grep '^Sig:'
nix config show trusted-public-keys
```

Compare the full consumer key with `cache-public-key.pem`. The signing key name
and base64 value must match. A `Sig` line alone is not proof of validity: use the
isolated copy and verification above. Fix the publisher/key configuration rather
than disabling signature requirements. Old entries retain their original
signatures when repeated native copies skip existing paths.

### Runtime dependencies or NAR objects missing

```bash
nix path-info --store "$cache" --recursive "$hello_path"
nix copy --from "$cache" --to "local?root=$verify_root" \
  --option trusted-public-keys "$public_key" "$hello_path"
```

Metadata may exist while its NAR or a referenced dependency is absent. Inspect the
narinfo `URL:` and download it with `curl -fI "$cache/RELATIVE_NAR_URL"`.
Rebuild and rerun recursive publication from the matching package revision. Do not
use `--no-recursive` or expire NAR objects independently of their metadata.

### Unexpected store paths or local compilation

```bash
nix flake metadata --json | jq '.locks.nodes["my-packages"].locked'
nix config show substituters
nix build -vv --print-build-logs --no-link --impure --expr \
  '(builtins.getFlake (toString ./.)).inputs.my-packages.packages.x86_64-linux.hello'
sudo journalctl -u nix-daemon --since '15 minutes ago'
```

Compare the consumer's locked package revision and expected path with the CI
manifest for that revision. Check for nixpkgs overrides or `follows`, different
package options, a pending/failed publishing job, or a cache that is not yet
populated. `hello` is the custom output here; `nixpkgs#hello` requests a different
package. Configuration changes must be activated before the daemon uses them.
An already-present path does not produce a fresh download log.

Only `x86_64-linux` is exported. Requesting `aarch64-linux` fails evaluation;
there is no ARM build or cross-compilation pipeline. Keep the selected host
architecture and flake package system aligned.
