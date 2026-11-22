# Setup and operation: start to finish

Follow these steps in order. Finish the local Nix builds before configuring AWS
or GitHub publication. Steps 1–9 run on your development machine in this package
repository unless a step says otherwise. Steps 10–11 run in your separate NixOS
configuration repository. Later sections cover ongoing maintenance.

You will need an AWS account, a GitHub account with permission to configure the
repository, and an existing `x86_64-linux` NixOS host. The example names are
`YOUR_USER/nix-packages`, bucket `my-nix-binary-cache`, region `eu-north-1`, and
signing-key name `my-nix-cache-1`. Replace these consistently. Keep all credentials
and private signing keys out of Git and chat.

Local package builds and signed file-cache tests have passed. Live GitHub and AWS
checks remain for you to perform against your own resources.

## Steps

1. [Prepare local tools](#1-prepare-local-tools)
2. [Build and validate locally](#2-build-and-validate-locally)
3. [Prepare the GitHub repository](#3-prepare-the-github-repository)
4. [Create the public-read S3 bucket](#4-create-the-public-read-s3-bucket)
5. [Create the IAM publisher and access keys](#5-create-the-iam-publisher-and-access-keys)
6. [Generate the Nix signing key](#6-generate-the-nix-signing-key)
7. [Configure GitHub publication settings](#7-configure-github-publication-settings)
8. [Push master and run the workflow](#8-push-master-and-run-the-workflow)
9. [Verify the published cache](#9-verify-the-published-cache)
10. [Configure the NixOS consumer](#10-configure-the-nixos-consumer)
11. [Install and verify on NixOS](#11-install-and-verify-on-nixos)
12. [Add packages and publish updates](#12-add-packages-and-publish-updates)
13. [Publish manually when needed](#13-publish-manually-when-needed)
14. [Troubleshoot](#14-troubleshoot)
15. [Maintain credentials and storage](#15-maintain-credentials-and-storage)

## 1. Prepare local tools

NixOS includes Nix. On other Linux systems, install Nix using the
[official installation instructions](https://nixos.org/download/).

Use Nix with `flakes` and `nix-command` enabled, plus Bash and `jq` on PATH.
For a local Nix installation, add `experimental-features = nix-command flakes`
to `~/.config/nix/nix.conf`. On NixOS, set
`nix.settings.experimental-features = [ "nix-command" "flakes" ];` in a module.

To get the local script tools from the pinned nixpkgs, run
`nix shell --inputs-from . nixpkgs#jq nixpkgs#shellcheck nixpkgs#python3`
from the repository root. Install the AWS CLI for the verification steps with
`nix shell --inputs-from . nixpkgs#awscli2 nixpkgs#curl` when needed. Publishing
itself uses native Nix and does not require AWS CLI.

## 2. Build and validate locally

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

```bash
for script in scripts/*.sh; do bash -n "$script"; done
shellcheck scripts/*.sh
python3 tests/build-all.py
python3 tests/publish-cache.py
nix run --inputs-from . nixpkgs#actionlint -- .github/workflows/build.yml
```

Continue to step 3 only after these checks succeed.

The integration tests use temporary copies of the flake, the pinned nixpkgs,
and small real Nix builds. They need Python 3 and daemon/network access as needed
by Nix. Test packages do not remain in this repository.

## 3. Prepare the GitHub repository

In GitHub, create an empty repository named `nix-packages` under your account or
organization. Do not initialize another README or license on GitHub when using
this existing checkout. You need administrative access to configure its environment.

In this local package repository, inspect the branch and remotes:

```bash
git status
git branch --show-current
git remote -v
```

Keep the existing `master` branch. If no `origin` exists, add the empty
GitHub repository (use your actual owner and repository name):

```bash
git remote add origin git@github.com:YOUR_USER/nix-packages.git
```

Run each change only if needed. If using HTTPS instead of SSH, use
`https://github.com/YOUR_USER/nix-packages.git` and your configured GitHub credentials.
Do not push yet: first configure AWS and GitHub secrets in steps 4–7 so the first
master push can publish successfully.

## 4. Create the public-read S3 bucket

In S3, choose **Buckets → Create bucket → General purpose**. Pick a region
(for example `eu-north-1`) and a globally unique name such as
`my-nix-binary-cache`. Use lowercase letters, numbers, and hyphens without dots;
dotted names do not work with the regional HTTPS wildcard certificate used here.

Choose **Object Ownership → ACLs disabled (Bucket owner enforced)**. Retain
private writes; public downloads will use a bucket policy. Use S3 Standard for
objects, default SSE-S3 encryption, and no automatic expiration rules. SSE-KMS
would require additional permissions and does not suit anonymous downloads.
This bucket contains publicly downloadable binaries and metadata: never put
backups, source secrets, or confidential artifacts in it.

Under **Permissions → Block public access → Edit**, retain **BlockPublicAcls**
and **IgnorePublicAcls**. Disable **BlockPublicPolicy** and **RestrictPublicBuckets**
for this bucket, acknowledge the public-read intent, and save. Account and
organization restrictions override bucket settings; the most restrictive setting
wins. If an account-level policy blocks this setup, consult its administrator.
Changing account-wide restrictions affects other buckets as well: review their
policies first rather than disabling these controls blindly.

Under **Permissions → Bucket policy**, replace `BUCKET_NAME` below and save:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "PublicReadNixCache",
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::BUCKET_NAME/*"
  }]
}
```

`GetObject` permits downloading known cache objects. Anonymous clients do not
need `ListBucket` when using HTTPS. Never grant anonymous PUT or delete access.
Review all existing bucket objects before applying this policy: it exposes every
object. See [AWS Block Public Access](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html).

## 5. Create the IAM publisher and access keys

Open **IAM → Users → Create user**. Name it `github-nix-cache-publisher`; do not
enable AWS console access. Attach a dedicated inline or customer-managed policy,
replacing `BUCKET_NAME`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CacheBucketMetadata",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"],
      "Resource": "arn:aws:s3:::BUCKET_NAME"
    },
    {
      "Sid": "CacheObjectUploads",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": "arn:aws:s3:::BUCKET_NAME/*"
    }
  ]
}
```

These are the permissions documented for the Nix 2.34 S3 uploader, split by
bucket/object resource. The script enables multipart uploads for large objects;
`PutObject` covers starting, uploading parts, and completing uploads, while the
listed multipart actions support inspection and aborting failed uploads. No
delete permission or access to other buckets is granted. See the
[Nix S3 store manual](https://nix.dev/manual/nix/2.34/store/types/s3-binary-cache-store).

Select the user, open **Security credentials → Access keys → Create access key**,
choose the use case for an application outside AWS, and complete the wizard.
Copy both the access key ID and secret access key while shown. Store them securely;
the secret is shown only once. These AWS credentials authorize uploads and are
separate from the Nix signing key, which lets consumers verify cache contents.

To verify credentials locally, configure a dedicated AWS CLI profile with
`aws configure --profile nix-cache-publisher` (interactive prompts keep values out
of shell history), then run:

```bash
aws s3api get-bucket-location --bucket BUCKET_NAME --profile nix-cache-publisher
aws s3 ls s3://BUCKET_NAME/ --profile nix-cache-publisher
```

For rotation, create a second access key, update GitHub, test a publication, then
deactivate and delete the old key. Revoke leaked credentials immediately. Retain
no console password and avoid granting broader policies to this user.

## 6. Generate the Nix signing key

In a secure local directory outside the repository:

```bash
umask 077
nix-store --generate-binary-cache-key \
  my-nix-cache-1 cache-private-key.pem cache-public-key.pem
cat cache-public-key.pem
```

The private file signs cache entries. Save its complete contents as the GitHub
secret `NIX_CACHE_SIGNING_KEY` and keep a secure backup. Do not commit it. The
public file is safe to share; copy the entire `my-nix-cache-1:...` value into
consumers' `trusted-public-keys`. During signing-key rotation, distribute the new
public key before switching writers and retain old trust while old artifacts
remain in use. Existing destination paths are skipped by native copy; changing a
key does not automatically re-sign already uploaded entries.

## 7. Configure GitHub publication settings

Open **Repository → Settings → Environments → New environment**, create
`nix-cache`, and choose **Deployment branches and tags → Selected branches and
tags**. Add a **branch** rule for exactly `master`, with no tag rule. If `nix-cache`
already exists, edit its deployment branch rules from `main` to `master` and save.
This restriction protects environment secrets even if a different branch changes
its workflow.
Under this environment's secrets add the three secret values below; do not also
store publication secrets as broadly available repository secrets.

For variables, use **Settings → Secrets and variables → Actions → Variables →
New repository variable**. The workflow reads `secrets` and `vars` as follows:

| Name | Type | Purpose |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | Environment secret (`nix-cache`) | Dedicated IAM access key ID |
| `AWS_SECRET_ACCESS_KEY` | Environment secret (`nix-cache`) | IAM secret access key |
| `NIX_CACHE_SIGNING_KEY` | Environment secret (`nix-cache`) | Complete private signing key contents |
| `AWS_REGION` | Repository variable | Region, e.g. `eu-north-1` |
| `S3_BUCKET` | Repository variable | Bucket name only |

Environment secrets and branch restrictions require a GitHub plan that supports
them for the repository's visibility. See [GitHub environment setup](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments).

The workflow uses immutable action pins and installs official Nix 2.34.9 with
flakes and nix-command. Native S3 support is checked before publishing; AWS CLI
is not needed by CI. The Cachix action installs Nix only; no Cachix hosting is used.

PRs and manual runs on other branches validate and build without publication
secrets. Master pushes and master manual runs validate, build all packages, then
publish in the same job. A failed step prevents publication. Builds run without
AWS or signing environment variables; only the publishing step receives them.

## 8. Push master and run the workflow

After steps 4–7, return to the package repository. Commit any remaining reviewed
changes, then push:

```bash
git status
git push -u origin master
```

On GitHub, select `master` as the default branch under repository settings and
protect changes to master and workflow files. Open **Actions → Build and publish
packages** and wait for validation, package builds, and publication to succeed.
Keep the commit hash of the successful run for the verification below.

To run manually, open **Actions → Build and publish packages → Run workflow**,
choose **master**, and run. The workflow must first exist on the default branch for
the button to appear. No external GitHub workflow run has been performed during
local validation.

## 9. Verify the published cache

The scripts `scripts/verify-cache.sh` and `scripts/run-cached-hello.sh` automate
the object, signature, closure, and Hello checks below. They require `aws`, `curl`,
`jq`, and `nix` for verification; the Hello runner needs `curl` and `nix`. Run
`--help` for the argument list.

Uploads use authenticated
`s3://BUCKET_NAME?region=REGION&secret-key=TEMPORARY_KEY_FILE`; consumers use
`https://BUCKET_NAME.s3.REGION.amazonaws.com` without AWS credentials. For example:
`https://my-nix-binary-cache.s3.eu-north-1.amazonaws.com`.
Use the bucket's real region; do not use S3 website endpoints.

After a successful master publication, from the package repository checked out at the same commit as the successful workflow:

```bash
./scripts/verify-cache.sh \
  --cache-url https://my-nix-binary-cache.s3.eu-north-1.amazonaws.com \
  --bucket my-nix-binary-cache \
  --region eu-north-1 \
  --aws-profile nix-cache-publisher \
  --public-key 'my-nix-cache-1:REPLACE_WITH_FULL_PUBLIC_KEY'
```

The utility lists objects through the selected AWS CLI profile, fetches
`nix-cache-info` and the Hello narinfo anonymously, checks the path and signature
name, verifies that the NAR is downloadable, then restores and cryptographically
verifies the closure in an isolated temporary store. It removes that temporary
store on exit.

To test anonymous writes, explicitly add `--check-anonymous-write`. This sends a
PUT request for a unique probe object. If S3 accepts it, the script reports a
security failure and prints the key so an administrator can remove the object;
the publisher account intentionally has no delete permission. Without this flag,
the script makes no writes to S3.

You can provide a specific store path to inspect a different published package:

```bash
./scripts/verify-cache.sh --cache-url https://my-nix-binary-cache.s3.eu-north-1.amazonaws.com \
  --bucket my-nix-binary-cache --region eu-north-1 \
  --public-key 'my-nix-cache-1:REPLACE_WITH_FULL_PUBLIC_KEY' \
  --store-path /nix/store/STORE_HASH-package-version
```

Run Hello using the custom cache as an additional substituter:

```bash
./scripts/run-cached-hello.sh \
  --cache-url https://my-nix-binary-cache.s3.eu-north-1.amazonaws.com \
  --public-key 'my-nix-cache-1:REPLACE_WITH_FULL_PUBLIC_KEY'
```

It checks that this repository's exact `.#hello` store path is signed and
available from the cache, adds that cache and key to Nix for the build, then runs
the resulting program. If the path is already in the active store, Nix may reuse
it without a network download. To observe a fresh download, use a machine where
that output is absent; do not delete paths from a production store.

403 reads can mean account-level public access blocking, a bad policy, or a
missing object when anonymous listing is denied. Check authenticated object
existence with `aws s3api head-object --bucket "$S3_BUCKET" --key KEY --profile
nix-cache-publisher`. A missing `nix-cache-info` means publication has not completed
or the endpoint is wrong. Check region, bucket, master workflow logs, and IAM policy.
Incorrect signatures require matching consumer keys and the exact package revision.

## 10. Configure the NixOS consumer

In your separate NixOS configuration repository:

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
**complete** public-key line generated in [step 6](#6-generate-the-nix-signing-key), including its
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

## 11. Install and verify on NixOS

The NixOS flake's `flake.lock` pins a particular revision of this package repository.
The package repository's own lock independently pins nixpkgs; CI builds that
revision. Do not add `my-packages.inputs.nixpkgs.follows = "nixpkgs"` by default or
otherwise override that input. A different dependency graph can change derivation
and store paths, making uploaded substitutes unusable for the requested build.
Updating the NixOS flake's own nixpkgs does not require changing the package pin.

Enable the cache settings on the machine before expecting substitution. On the
first rebuild, the running daemon still has the previous cache configuration;
you can first apply the cache module without the new packages, then add them and
rebuild. Do not interpret a local first build as proof the cache is broken.

After adding the input, update only that input, review and commit your lock file:

```bash
nix flake update my-packages
sudo nixos-rebuild switch --flake .#my-host
hello
peek --version
```

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

## 12. Add packages and publish updates

### Add a package in the package repository

Create `packages/my-tool/package.nix` returning a derivation accepted by
`pkgs.callPackage`. The directory name becomes the flake package name. Supporting
sources and patches can live alongside it. Loose files and directories without a
regular `package.nix` are ignored.

Stage new package files with `git add packages/my-tool` so Git-backed flake
evaluation can see them. Run `nix flake show`, `nix build .#my-tool`, and
`./scripts/build-all.sh`, then commit. Package discovery requires no changes to
the flake or CI configuration.

### Update the package repository’s nixpkgs pin

Update the independent nixpkgs pin with `nix flake update nixpkgs`, then rerun
validation and builds. Dependency changes can change derivation and output paths.
Commit `flake.lock` with the update.

### Publish and consume a new revision

1. Change a package definition in the package repository and push to trusted `master`.
2. Wait for CI to build and publish successfully.
3. In the separate NixOS repository, run `nix flake update my-packages`.
4. Review and commit its lock file, rebuild the host, and inspect substitution logs.

New upstream commits are not consumed automatically: your NixOS lock file remains
pinned until explicitly updated. Use the corresponding package repository commit
when comparing CI and consumer output paths.

## 13. Publish manually when needed

Complete steps 4–7 first. Normal builds never publish.
For an authorized manual upload, return to the package repository and use an
interactive shell with tracing disabled:

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

## 14. Troubleshoot

In the NixOS configuration repository, initialize the diagnostic values again if
using a new terminal. Replace the bucket/region and paste the full public key:

```bash
cache='https://BUCKET_NAME.s3.REGION.amazonaws.com'
public_key='my-nix-cache-1:REPLACE_WITH_FULL_PUBLIC_KEY'
hello_path=$(nix eval --impure --raw --expr \
  '(builtins.getFlake (toString ./.)).inputs.my-packages.packages.x86_64-linux.hello.outPath')
verify_root=$(mktemp -d)
```

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
shown in [step 9](#9-verify-the-published-cache). Do not solve anonymous reads by adding AWS
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

## 15. Maintain credentials and storage

Budget for stored GB-months, PUT and GET requests, internet transfer, and GitHub
Actions build minutes. Runtime closures include dependencies and can be much
larger than the custom package alone. Old revisions accumulate. This project does
not delete cache entries or configure lifecycle expiration. Do not expire `nar/`
objects blindly: surviving narinfo records may still reference them. Future cache
collection must track reachability and remove metadata and NARs consistently.

Review public bucket contents and IAM permissions periodically, rotate access
keys, keep signing backups secure, and allow only trusted branch code to publish.
AWS upload, public HTTPS reads, IAM permissions and GitHub execution must be tested
against your provisioned resources; they have not been tested by the local suite.
