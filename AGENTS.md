# Implementation Specification: Custom Nix Packages with GitHub Actions and AWS S3 Binary Cache

## 1. Objective

Implement a standalone Git repository for maintaining custom Nix packages.

The repository must:

1. Define custom packages using Nix derivations.
2. Automatically discover new packages added to the repository.
3. Expose packages through standard Nix flake outputs.
4. Build all custom packages through GitHub Actions.
5. Publish signed Nix binary cache artifacts to AWS S3.
6. Allow existing NixOS configuration flakes to consume those packages.
7. Allow NixOS machines to download prebuilt packages directly from S3 over HTTPS.
8. Document all manual AWS, GitHub and NixOS setup steps.

GNU Hello must be included as the initial example package.

The result should be simple, inexpensive to operate, reproducible and easy to maintain.

**Implement the complete project, including code, workflows, scripts, tests and documentation. Do not stop at a design proposal.**

Make reasonable implementation decisions independently. Do not introduce additional infrastructure or abstractions beyond those required by this specification.

---

## 2. Fixed architectural decisions

These decisions are final and must be followed.

### Package repository

- The custom packages live in their own Git repository.
- The repository is an independent Nix flake.
- It maintains its own `flake.lock`.
- It can be referenced from another Nix flake using a GitHub flake input.
- Adding packages must not require changing the GitHub Actions workflow.

### Build system

- GitHub Actions builds the packages.
- Build targets are discovered automatically from the flake outputs.
- Initially support `x86_64-linux`.
- The NixOS system configuration itself is not built in this repository.
- Pull requests validate builds without publishing anything.
- Pushes to `master` build and publish packages.

### Storage

Use **AWS S3 exclusively**.

Do not implement support for Cloudflare R2, Backblaze B2, Hetzner, or generic S3-compatible providers.

Use Nix's native S3 binary cache support.

### Authentication

Use an AWS IAM user with long-lived access keys.

GitHub Actions receives credentials through:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

Do not implement GitHub OIDC or IAM role assumption.

Use a dedicated IAM user with permissions restricted to the cache bucket.

### Cache access

NixOS machines consume the cache using the bucket's regional HTTPS endpoint:

```text
https://BUCKET_NAME.s3.REGION.amazonaws.com
```

Do not introduce CloudFront, custom domains, reverse proxies or dedicated Nix cache servers.

The bucket must support anonymous, read-only access to the published Nix cache objects.

Uploads must remain authenticated.

### Signing

Use standard Nix binary cache signing.

The signing private key must be available only to GitHub Actions publishing jobs.

Consumers must trust the corresponding public key.

### Infrastructure scope

Do not use:

- Terraform
- CloudFormation
- EC2
- Lambda
- CloudFront
- Route 53
- Containers or Kubernetes
- Cachix hosting
- Attic
- Hydra
- A database
- A dedicated binary cache service

Only GitHub Actions, AWS S3, AWS IAM and standard Nix tooling are required.

---

## 3. Repository structure

Create this repository structure:

```text
nix-packages/
├── flake.nix
├── flake.lock
├── README.md
├── .gitignore
│
├── packages/
│   └── hello/
│       └── package.nix
│
├── scripts/
│   ├── build-all.sh
│   └── publish-cache.sh
│
├── docs/
│   └── setup.md
│
└── .github/
    └── workflows/
        └── build.yml
```

Additional files may be created when justified, but keep the repository minimal.

The scripts should be executable.

Include `.gitignore` entries for:

- Nix build result symlinks
- Private signing keys
- Temporary files
- Local development artifacts

Never commit credentials.

---

## 4. Nix flake

Implement a standard `flake.nix`.

### Nixpkgs dependency

Use an appropriate nixpkgs input, initially tracking `nixos-unstable`:

```nix
{
  inputs.nixpkgs.url =
    "github:NixOS/nixpkgs/nixos-unstable";
}
```

Generate and commit `flake.lock`.

The repository must pin its own nixpkgs revision independently of consuming NixOS configurations.

This is important because GitHub Actions and the NixOS consumers must evaluate matching package derivations to obtain binary cache hits.

Do not configure `inputs.nixpkgs.follows` from the consuming NixOS flake by default.

### Supported system

Initially:

```nix
system = "x86_64-linux";
```

Organize the implementation so another system, such as `aarch64-linux`, can be added later without redesigning package discovery or publishing.

Do not implement cross-compilation unless necessary.

### Package discovery

This is an important requirement.

**New packages must be automatically discovered from the `packages/` directory.**

Use standard Nix functionality such as:

- `builtins.readDir`
- `builtins.attrNames`
- `builtins.filter`
- `builtins.listToAttrs`
- `pkgs.callPackage`

Each immediate directory inside `packages/` containing a regular `package.nix` file represents one package.

The package name should be derived from its directory name.

For example:

```text
packages/
├── hello/
│   └── package.nix
├── foo/
│   └── package.nix
└── bar/
    └── package.nix
```

Must expose:

```text
packages.x86_64-linux.hello
packages.x86_64-linux.foo
packages.x86_64-linux.bar
```

The implementation must:

- Ignore loose files and directories without a regular `package.nix`.
- Discover only immediate package directories; do not recursively import nested directories.
- Avoid maintaining a duplicate package registry.
- Produce understandable evaluation errors for invalid package files.
- Use `pkgs.callPackage` to evaluate package definitions.
- Make newly added package files available to CI automatically.

Do not hardcode the package names in `flake.nix` if automatic discovery can be implemented cleanly.

Use `packages/<name>/package.nix`, following the Nixpkgs per-package file convention without prefix grouping directories. Supporting files and patches may live alongside `package.nix`.

### Flake outputs

Export each package as:

```text
packages.x86_64-linux.<name>
```

Ensure:

```bash
nix flake show
```

Displays the custom packages.

Do not export the entire nixpkgs package set.

Only packages maintained in this repository should appear under the flake's `packages` output.

Optional checks may be exposed under `checks.x86_64-linux`.

Do not require an aggregate `default` derivation for CI. Prefer dynamically enumerating the package outputs.

---

## 5. Example package: GNU Hello

Create:

```text
packages/hello/package.nix
```

The package should be a customized version of GNU Hello.

### Requirements

Define GNU Hello directly with `stdenv.mkDerivation`, fetching a pinned upstream source release with a fixed hash. Do not use `pkgs.hello`, overrides, or an alias as the implementation.

Use the standard build phases to configure, compile, test, and install GNU Hello, then add a small deterministic customization.

For example, install an additional file:

```text
$out/share/hello-custom/build-info.txt
```

The file may contain a deterministic message such as:

```text
GNU Hello built by the custom nix-packages repository.
```

Requirements:

- The custom derivation must be different from the standard `pkgs.hello` derivation.
- The resulting store path must differ from the unmodified nixpkgs package.
- The original GNU Hello executable must continue to work.
- The customization must be deterministic.
- Use the standard stdenv build phases and run the upstream test suite.
- Do not introduce unnecessary build-time dependencies.

The following commands must work:

```bash
nix build .#hello
./result/bin/hello
```

The executable should display GNU Hello's usual greeting.

Verify that the additional file exists in the output.

This example must demonstrate a genuine custom derivation, not simply an alias to `pkgs.hello`.

---

## 6. Automatic build script

Implement:

```text
scripts/build-all.sh
```

Purpose: build every custom package exposed by the flake for the selected system.

Usage:

```bash
./scripts/build-all.sh
```

### Requirements

The script must:

1. Determine the target system, defaulting to `x86_64-linux`.
2. Discover all package names from the flake outputs.
3. Construct corresponding Nix installables.
4. Build all of them.
5. Stop on build failures.
6. Produce the resulting Nix store output paths.
7. Make those paths available to the publishing script.
8. Support package names containing hyphens.
9. Handle an empty package set gracefully.
10. Avoid hardcoding package names.

Use stable, machine-readable output from Nix.

For example, package discovery can use:

```bash
nix eval --json --expr \
  'builtins.attrNames (builtins.getFlake (toString ./.)).packages.x86_64-linux'
```

The implementation may use a more appropriate equivalent if needed.

Use `jq` for parsing JSON where appropriate.

Prefer a single `nix build` invocation containing the discovered installables.

Do not parse formatted `nix flake show` output.

### Output handling

The build script must reliably communicate which store paths were built.

For example, it may write a newline-delimited file containing store paths.

Ensure the file is suitable for passing to:

```bash
nix copy --to ...
```

A crucial requirement is that publishing must include all relevant outputs of built derivations, including multiple outputs when applicable.

Do not silently ignore outputs such as `dev`, `lib` or `doc` when a custom package produces them.

Choose a robust implementation using the Nix CLI's machine-readable output.

### Local usability

The script should also be usable by a developer without AWS credentials.

Building packages must not automatically publish them.

---

## 7. AWS S3 binary cache publishing

Implement:

```text
scripts/publish-cache.sh
```

Purpose: upload built store paths to AWS S3 using the native Nix binary cache implementation.

### Configuration

Use the following environment variables.

Required:

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_REGION
S3_BUCKET
NIX_CACHE_SIGNING_KEY
```

The signing key is supplied as the key's contents, not as a pre-existing filename.

Do not hardcode region, bucket name, AWS account ID or credentials.

Do not require AWS CLI for normal publishing unless necessary.

### Nix S3 store

Use the native Nix S3 backend.

Conceptually:

```bash
nix copy \
  --to "s3://${S3_BUCKET}?region=${AWS_REGION}&secret-key=${KEY_FILE}" \
  "${OUTPUTS[@]}"
```

`KEY_FILE` must be the path to a temporary file containing the Nix signing private key.

Validate the precise command and URL parameters against the installed Nix version.

### Signing key handling

The script must:

1. Read `NIX_CACHE_SIGNING_KEY` from the environment.
2. Create a temporary file with restrictive permissions.
3. Write the key to that file.
4. Use it for signing exported cache entries.
5. Delete the temporary file on success or failure.

Use restrictive permissions such as `0600`.

Do not print the key.

Do not enable shell tracing around secret handling.

### Upload behavior

The script must:

- Upload the store paths produced by `build-all.sh`.
- Publish usable Nix binary cache artifacts.
- Sign the resulting cache entries.
- Return a nonzero exit code on failure.
- Support repeated execution safely.
- Avoid unnecessary copying when paths already exist in the destination.
- Fail clearly if required environment variables are missing.

### Runtime closures

The first implementation should prioritize correctness.

By default, upload the runtime closure of each custom package.

This ensures that dependencies not available in the standard NixOS binary cache are also accessible.

It is acceptable if this initially uploads some standard nixpkgs dependencies already available from `cache.nixos.org`.

Document that this may increase storage consumption.

Do not optimize by using `--no-recursive` unless the implementation also guarantees that all necessary custom dependencies remain available.

A future optimization may selectively exclude dependencies known to be available in the official NixOS cache, but this is out of scope.

### Binary cache structure

The resulting S3 bucket should contain standard Nix binary cache objects, including:

```text
nix-cache-info
<store-hash>.narinfo
nar/
    <nar-object>
```

Verify that metadata and references are correct and that `.narinfo` files contain the expected Nix signature.

Prefer native Nix binary-cache functionality rather than constructing these objects manually.

---

## 8. GitHub Actions workflow

Implement:

```text
.github/workflows/build.yml
```

The workflow must support:

- Pull requests.
- Pushes to `master`.
- Manual execution using `workflow_dispatch`.

### Build job

The build job must:

1. Check out the repository.
2. Install Nix.
3. Ensure experimental flake and nix-command features are available.
4. Validate the flake.
5. Build every custom package automatically.
6. Fail when validation or a build fails.

Use a current, supported Nix installation action.

It is acceptable to use `cachix/install-nix-action` solely to install Nix.

Do not use the Cachix binary cache hosting service.

Use appropriate GitHub Actions token permissions, such as:

```yaml
permissions:
  contents: read
```

Prefer immutable action commit pins where practical.

### Pull requests

On pull requests:

- Run validation and package builds.
- Do not publish.
- Do not expose AWS credentials.
- Do not expose the Nix signing private key.

Do not use a privileged `pull_request_target` workflow to run untrusted package code.

### Main branch

On pushes to `master`:

1. Check out the source.
2. Install Nix.
3. Run `nix flake check`.
4. Run `scripts/build-all.sh`.
5. Run `scripts/publish-cache.sh`.

Publishing must occur only after successful validation and builds.

### Manual execution

`workflow_dispatch` must execute the build and publishing pipeline on the selected ref only when permitted by the workflow's publication rules.

Do not allow arbitrary untrusted refs to access publishing secrets.

Prefer publishing only from `master`.

### GitHub secrets

Configure:

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
NIX_CACHE_SIGNING_KEY
```

### GitHub variables

Configure:

```text
AWS_REGION
S3_BUCKET
```

Use GitHub Actions `secrets` and `vars` contexts correctly.

### S3 support

Ensure the installed Nix version supports the native S3 store.

If a specific Nix installation option or package is required for S3 support, configure and document it.

### No package enumeration

The workflow must never contain an explicit package list such as:

```bash
nix build .#hello .#another-tool
```

Adding a new package must not require workflow modifications.

All builds must be driven through the package discovery mechanism and build script.

---

Cache verification utilities should accept the cache HTTPS URL, bucket, region, public key, and an optional store path or AWS CLI profile. Keep anonymous-write checks explicit because a misconfigured bucket could accept and retain the probe object. Provide a separate utility that checks and runs GNU Hello using the cache and public key.

## 9. AWS setup documentation

Include the following AWS steps in the consolidated guide:

```text
docs/setup.md
```

This must be a detailed, self-contained guide for manually provisioning the required AWS infrastructure.

Assume the reader has an AWS account but has not yet created the cache bucket or IAM credentials.

Use the AWS console as the primary setup method.

Where useful, provide equivalent AWS CLI commands.

### 9.1 Create an S3 bucket

Document:

- How to create a new general-purpose S3 bucket.
- How to select the AWS region.
- How to choose a globally unique bucket name.
- How to select S3 Standard storage.
- How to configure Object Ownership.
- How to keep write access private.
- How to configure public object downloads.

Use `eu-north-1` as an example region, without hardcoding it into scripts.

Use a placeholder bucket name such as:

```text
my-nix-binary-cache
```

Explain that the bucket contains publicly downloadable compiled binaries and metadata.

Do not use this bucket for private backups or confidential artifacts.

### 9.2 S3 public-read policy

Document the required S3 Block Public Access configuration.

Explain how bucket-level and account-level public access restrictions interact.

Retain ACL blocking where possible and use bucket policies rather than public object ACLs.

Provide an example bucket policy granting anonymous `s3:GetObject` access:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadNixCache",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::BUCKET_NAME/*"
    }
  ]
}
```

Explain:

- Why `s3:GetObject` is required.
- Why anonymous users do not need `s3:ListBucket`.
- Why public write permissions must never be granted.
- Which S3 Block Public Access options need adjustment.
- Why the user should verify that no other bucket data is exposed.

Do not recommend disabling AWS account-wide public access restrictions without explicitly explaining the broader security implications.

### 9.3 IAM user for GitHub Actions

Document creating a dedicated IAM user, for example:

```text
github-nix-cache-publisher
```

The user should have programmatic access only.

Provide a least-privilege IAM policy for the specific S3 bucket.

An illustrative policy is:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListCacheBucket",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": "arn:aws:s3:::BUCKET_NAME"
    },
    {
      "Sid": "ReadWriteCacheObjects",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:AbortMultipartUpload"
      ],
      "Resource": "arn:aws:s3:::BUCKET_NAME/*"
    }
  ]
}
```

Check the exact permissions required by the implemented Nix S3 uploader, including multipart upload behavior.

Do not add permissions such as:

```text
s3:*
```

Do not grant access to unrelated buckets.

Avoid delete permissions unless demonstrably required.

### 9.4 Generate access keys

Document:

1. Opening IAM.
2. Selecting the dedicated publisher user.
3. Creating an access key.
4. Copying the access key ID.
5. Copying the secret access key.
6. Storing both as GitHub Actions secrets.
7. Verifying access.

Explain how to rotate or revoke credentials later.

Clearly note that AWS access keys are different from Nix signing keys.

### 9.5 Generate Nix signing keys

Show a concrete command:

```bash
nix-store --generate-binary-cache-key \
  my-nix-cache-1 \
  cache-private-key.pem \
  cache-public-key.pem
```

Document the purpose of each file.

The private key must be stored securely and added to the GitHub Actions secret:

```text
NIX_CACHE_SIGNING_KEY
```

The public key must be placed in consuming NixOS configurations.

The public key is not secret.

Include instructions to view the public key:

```bash
cat cache-public-key.pem
```

Explain that the public key value includes its key name and must be copied accurately.

### 9.6 Configure GitHub

Document the exact repository settings navigation for configuring Actions secrets and variables.

Provide a table:

| Name | Type | Purpose |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | Secret | IAM access key ID |
| `AWS_SECRET_ACCESS_KEY` | Secret | IAM secret access key |
| `NIX_CACHE_SIGNING_KEY` | Secret | Nix cache signing private key |
| `AWS_REGION` | Variable | AWS region |
| `S3_BUCKET` | Variable | S3 bucket name |

Explain how to trigger the GitHub Actions workflow manually.

### 9.7 Direct S3 HTTPS endpoint

Document the regional bucket URL:

```text
https://BUCKET_NAME.s3.REGION.amazonaws.com
```

For example:

```text
https://my-nix-binary-cache.s3.eu-north-1.amazonaws.com
```

Explain the difference between:

- The authenticated S3 URL used by Nix to upload.
- The public HTTPS URL used by NixOS to download.

The consumers must not require AWS credentials.

Do not use an S3 static website endpoint or a custom domain.

Document how bucket naming and AWS region affect endpoint formatting.

### 9.8 Verify uploaded cache objects

Provide commands that:

1. List the objects using authenticated AWS CLI access.
2. Download `nix-cache-info` using anonymous HTTPS.
3. Find a `.narinfo` file corresponding to GNU Hello.
4. Download the `.narinfo` file.
5. Verify the expected signature is present.
6. Confirm the referenced NAR object exists and is downloadable.
7. Demonstrate that no anonymous upload permissions exist.

Use `curl` and AWS CLI as appropriate.

### 9.9 Storage costs

Document the main cost components:

- Stored GB-months.
- PUT requests.
- GET requests.
- Internet data transfer.
- GitHub Actions build minutes.

Explain that recursively uploading Nix store closures can consume more storage than the custom derivation alone.

Mention that old package versions accumulate unless explicitly cleaned up.

Do not implement automatic cache deletion in the initial version.

Do not recommend blindly expiring objects under `nar/`, because that can invalidate existing `.narinfo` metadata.

Describe safe, future reachability-aware garbage collection as a possible improvement.

### 9.10 Security

Document:

- The risks of public S3 buckets.
- Least-privilege IAM permissions.
- Separation of publication credentials and cache signing keys.
- GitHub Actions secret protection.
- Credential rotation.
- Why only trusted branches should publish.
- Why the S3 bucket should be dedicated to the binary cache.

---

## 10. NixOS integration documentation

Include the following consumer steps in the same consolidated guide:

```text
docs/setup.md
```

This should explain how to use the package repository from an entirely separate NixOS configuration flake.

The guide must not assume any particular existing NixOS repository structure.

### 10.1 Add the flake input

Provide a complete example:

```nix
{
  inputs = {
    nixpkgs.url =
      "github:NixOS/nixpkgs/nixos-unstable";

    my-packages.url =
      "github:YOUR_USER/nix-packages";
  };

  outputs = { nixpkgs, my-packages, ... }: {
    nixosConfigurations.my-host =
      nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";

        modules = [
          ({ ... }: {
            environment.systemPackages = [
              my-packages.packages.x86_64-linux.hello
            ];
          })
        ];
      };
  };
}
```

Explain how to integrate the input into an existing configuration instead of replacing the user's entire `flake.nix`.

### 10.2 Pinning and reproducibility

Explain:

- The consuming flake pins the package repository revision in its own `flake.lock`.
- The package repository pins nixpkgs independently.
- GitHub Actions builds against the package repository's lock file.
- Consumers should not override its nixpkgs input by default.
- Changing its nixpkgs inputs may change derivation paths and prevent cache hits.

Explain that package definitions must match the derivations built by GitHub Actions.

### 10.3 Configure the binary cache

Show:

```nix
{
  nix.settings = {
    substituters = [
      "https://cache.nixos.org"
      "https://BUCKET_NAME.s3.REGION.amazonaws.com"
    ];

    trusted-public-keys = [
      "my-nix-cache-1:PUBLIC_KEY"
    ];
  };
}
```

Document:

- Replacing placeholders.
- Using the public signing key.
- Keeping the official NixOS cache.
- How Nix selects substitutes.
- That both substituters may be queried.
- That custom package paths can be downloaded from S3.
- That standard packages should generally remain available from `cache.nixos.org`.
- That Nix can build locally when an expected substitute is unavailable.

Explain how to configure substituters using a normal NixOS module in an existing repository.

### 10.4 Install GNU Hello

Show how to add:

```nix
my-packages.packages.x86_64-linux.hello
```

To:

```nix
environment.systemPackages
```

And rebuild:

```bash
sudo nixos-rebuild switch --flake .#my-host
```

Verify the package:

```bash
hello
```

Also show how to inspect the custom build-information file.

### 10.5 Update packages

Document the intended release process:

1. Update a package in the custom package repository.
2. Commit and push to `master`.
3. GitHub Actions builds the new package output.
4. GitHub Actions uploads the binary cache artifacts to S3.
5. Update the `my-packages` flake input in the NixOS configuration.
6. Rebuild NixOS.
7. Verify that the binary was downloaded from the cache.

Use the correct supported Nix CLI command for updating only the `my-packages` flake input.

Explain that the NixOS configuration will not automatically update to new package commits until its lock file is updated.

### 10.6 Verify cache substitution

Provide practical commands for:

- Evaluating the expected package store path.
- Inspecting the store path produced by the flake.
- Checking whether the path is available in the S3-backed cache.
- Showing whether a build will download substitutes or compile locally.
- Inspecting logs when the cache is not being used.

Include a suitable `nix build --dry-run` example.

For stronger validation, document how to test substitution using an isolated temporary Nix store or another safe method, without deleting an existing production store path.

Do not recommend dangerous commands that remove store paths from the active NixOS installation merely to test the cache.

### 10.7 Troubleshooting

Cover:

- Incorrect bucket URL.
- Incorrect region.
- S3 HTTP 403 errors.
- S3 HTTP 404 errors.
- Missing `nix-cache-info`.
- Unsigned or incorrectly signed `.narinfo` records.
- Mismatched signing public keys.
- Missing runtime dependencies.
- Different `flake.lock` revisions.
- Overridden nixpkgs inputs.
- Unsupported architecture.
- Cache not populated yet.
- Incorrect expected store paths.
- Nix building locally instead of substituting.

Provide commands and explanations rather than only a list of possible causes.

---

## 11. Local development documentation

Include local development in the same consolidated guide:

```text
docs/setup.md
```

Document the following.

### Requirements

Explain how to install or enable:

- Nix
- Flakes
- `nix-command`
- `jq` if required by the scripts

### Build GNU Hello

```bash
nix build .#hello
./result/bin/hello
```

### Build everything

```bash
./scripts/build-all.sh
```

### Add a new package

Document the exact procedure.

For example:

1. Create `packages/my-tool/package.nix`.
2. Define a valid Nix derivation.
3. Run `nix flake show`.
4. Run `nix build .#my-tool`.
5. Run `./scripts/build-all.sh`.
6. Commit and push.

Make clear that no changes to the GitHub Actions workflow are necessary.

Ideally, no change to `flake.nix` should be necessary either.

### Validate the repository

```bash
nix flake check
```

Document additional tests where appropriate.

### Update nixpkgs

Show how to update `flake.lock`.

Explain how dependency updates can change the resulting store paths.

### Manual publishing

Document how a developer could publish packages manually when appropriate AWS credentials and the Nix signing key are available.

Warn against placing credentials directly into committed shell scripts or terminal history.

---

## 12. README

Create `README.md`.

It should contain:

1. Project purpose.
2. A short architectural overview.
3. The repository layout.
4. GNU Hello quick-start example.
5. How to build all packages.
6. How packages are discovered.
7. How GitHub Actions publishing works.
8. Where binaries are stored.
9. How NixOS consumes the packages.
10. Links to detailed setup documentation.

Keep the README concise.

Put all detailed setup, development, and NixOS instructions in one ordered `docs/setup.md` guide rather than splitting them across documents.

---

## 13. Testing and validation

Implement and perform the following checks.

### 13.1 Flake validation

Verify that:

```bash
nix flake show
```

Lists GNU Hello.

Verify that:

```bash
nix flake check
```

Succeeds.

### 13.2 Hello build

Verify:

```bash
nix build .#hello
./result/bin/hello
```

The executable must work.

Verify the custom metadata file exists.

Verify the package output is different from standard `pkgs.hello`.

### 13.3 Automatic package discovery

Test the discovery mechanism using a second temporary example package or an equivalent automated test.

Verify that:

- A new package file becomes visible in flake outputs.
- `build-all.sh` includes it.
- The GitHub Actions workflow does not require changes.
- Removing a package file removes it from the exported package list.

Do not leave unnecessary test packages in the final repository.

### 13.4 Build script

Verify that the build script:

- Discovers all packages.
- Builds all of them.
- Reports failures.
- Produces valid store paths.
- Handles output paths correctly.
- Supports repeated execution.

### 13.5 Publishing validation

Where AWS credentials are available, test actual publication to a dedicated test bucket or the intended cache bucket.

Verify:

- Objects are uploaded.
- Binary cache metadata exists.
- NAR objects exist.
- Entries are signed.
- Public HTTPS reads work.
- Nix can substitute the resulting package.

Where AWS credentials are unavailable, validate script syntax and static configuration, and document what has not been tested.

Never claim a successful end-to-end S3 test without performing one.

### 13.6 GitHub Actions

Validate the workflow YAML.

Verify its conditions ensure:

- Pull requests build without publishing.
- Pushes to `master` publish.
- Manual publishing cannot expose secrets to arbitrary untrusted refs.
- Publishing is skipped when builds fail.
- All package outputs are discovered automatically.

### 13.7 Shell scripts

Use shell syntax checks and ShellCheck where available.

Ensure scripts are robust under:

```bash
set -euo pipefail
```

Handle temporary files safely.

---

## 14. Acceptance criteria

The project is complete only when the following conditions are met.

### Repository

- [ ] Standalone Nix flake repository exists.
- [ ] `flake.lock` is committed.
- [ ] `packages/` contains the GNU Hello example.
- [ ] Package discovery is automatic.
- [ ] No duplicate package lists are maintained.

### Packages

- [ ] `.#hello` builds successfully.
- [ ] GNU Hello runs correctly.
- [ ] The example contains a deterministic customization.
- [ ] Its derivation differs from standard GNU Hello.
- [ ] Adding packages requires no CI workflow changes.

### Builds

- [ ] All exported custom packages can be built with one script.
- [ ] The build script discovers package outputs automatically.
- [ ] Build failures cause CI failures.
- [ ] All relevant built outputs can be published.

### GitHub Actions

- [ ] Pull requests validate builds.
- [ ] Pushes to `master` build and publish.
- [ ] `workflow_dispatch` exists.
- [ ] AWS credentials are provided through secrets.
- [ ] AWS credentials are not available to PR validation.
- [ ] Publication is restricted to trusted branch execution.
- [ ] No package list is hardcoded into the workflow.

### AWS S3

- [ ] AWS S3 is the only supported backend.
- [ ] Publishing uses native Nix S3 functionality.
- [ ] IAM access keys are used.
- [ ] No OIDC authentication is introduced.
- [ ] Uploaded cache artifacts are signed.
- [ ] The S3 endpoint can be consumed via HTTPS.
- [ ] Anonymous readers cannot modify cache objects.
- [ ] No extra HTTP proxy or cache server is required.

### NixOS

- [ ] NixOS can import the package repository as a flake input.
- [ ] NixOS can install the custom GNU Hello derivation.
- [ ] NixOS can use the public S3 binary cache.
- [ ] The cache signing public key is documented.
- [ ] Package updates and lock-file management are documented.
- [ ] Cache verification instructions exist.

### Documentation

- [ ] AWS bucket provisioning is documented.
- [ ] IAM user and access key setup are documented.
- [ ] Public-read bucket policy is documented.
- [ ] Nix signing key generation is documented.
- [ ] GitHub Actions secret configuration is documented.
- [ ] Local development is documented.
- [ ] NixOS integration is documented.
- [ ] Troubleshooting is documented.
- [ ] Storage costs and maintenance considerations are documented.

---

## 15. Non-goals

Do not implement:

- NixOS system builds.
- Remote Nix builders.
- Automatic deployment to NixOS machines.
- ARM builds.
- Cross-compilation.
- AWS infrastructure automation.
- Cache garbage collection.
- Multi-provider storage support.
- Cache authentication for consumers.
- A hosted cache application.
- Automatic package releases or semantic versioning.
- Scheduled dependency updates.
- Package-specific GitHub Actions jobs.
- Complex CI build matrices.
- Containers or virtualization infrastructure.

The objective is a small standalone Nix packages repository with a working S3 binary cache publishing pipeline.

---

## 16. Engineering principles

Follow these principles:

**Simplicity:** Prefer native Nix tools over third-party applications.

**Reproducibility:** Keep package definitions and nixpkgs pinned.

**Consistency:** CI and NixOS consumers must evaluate matching derivations.

**Automatic discovery:** Adding packages should require only adding package definitions.

**Security:** Protect AWS credentials and the Nix private signing key.

**Correctness:** Prioritize working binary substitution over premature storage optimization.

**Portability:** Keep the package definitions independent of the user's NixOS configuration.

**Maintainability:** Avoid unnecessary layers of scripts, abstractions or configuration.

---

## 17. Final deliverables

At completion, provide:

### A. Implemented repository

All Nix files, scripts, GitHub Actions workflows and documentation.

### B. Repository overview

Show the final file tree and briefly describe the major components.

### C. Local verification

Provide the exact commands to:

- Validate the flake.
- Build GNU Hello.
- Run GNU Hello.
- Build all custom packages.
- Verify automatic discovery.

### D. Manual setup checklist

Summarize the required manual steps:

1. Create an AWS S3 bucket.
2. Configure public-read access.
3. Create a dedicated IAM user.
4. Attach least-privilege permissions.
5. Generate IAM access keys.
6. Generate the Nix signing key pair.
7. Add GitHub Actions secrets.
8. Add GitHub Actions variables.
9. Run the publishing workflow.
10. Verify the S3 cache contents.
11. Configure NixOS to consume the cache.

### E. NixOS integration instructions

Provide a minimal example showing:

- The custom packages flake input.
- Installation of `hello`.
- Configuration of the S3 substituter.
- Configuration of the signing public key.
- Updating the package repository flake input.
- Rebuilding NixOS.

### F. Test results

Report which checks actually ran and whether they passed.

Clearly distinguish local verification from AWS-dependent tests that require credentials.

### G. Limitations

List any known issues, compromises or operational considerations.

---

## 18. Definition of done

The final system must support this workflow without any manual package enumeration:

1. A developer adds `packages/<name>/package.nix`.
2. The flake automatically exposes it.
3. The developer commits and pushes to `master`.
4. GitHub Actions discovers and builds all custom packages.
5. GitHub Actions signs and uploads the resulting store paths to AWS S3.
6. An existing NixOS flake consumes the package repository as an input.
7. The NixOS configuration installs a selected custom package.
8. Nix downloads the prebuilt package from the public S3 endpoint when a matching substitute exists.
9. Normal nixpkgs packages continue to use the official NixOS binary cache.

The finished implementation should require no specialized cache service, no continuously running server, and no manual changes to CI when additional custom packages are introduced.

**Proceed with implementing the project in the current working repository.**
