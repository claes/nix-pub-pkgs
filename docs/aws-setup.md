# AWS S3 cache and GitHub setup

This guide provisions a dedicated public binary cache using the AWS console.
The scripts support AWS S3 only. They do not create infrastructure.

## 1. Create the bucket

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

## 2. Create the publisher IAM user

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

## 3. Generate a Nix signing key

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

## 4. Configure GitHub

The workflow publishes only on `main`. This repository was initially created on
`master`: create/rename the trusted branch to `main` and select it as the GitHub
default branch before enabling publication. Protect changes to main and workflows.

Open **Repository → Settings → Environments → New environment**, create
`nix-cache`, and choose **Deployment branches and tags → Selected branches and
tags**. Add a **branch** rule for exactly `main`, with no tag rule. This restriction
protects environment secrets even if a different branch changes its workflow.
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
secrets. Main pushes and main manual runs validate, build all packages, then
publish in the same job. A failed step prevents publication. Builds run without
AWS or signing environment variables; only the publishing step receives them.

To run manually, open **Actions → Build and publish packages → Run workflow**,
choose **main**, and run. The workflow must first exist on the default branch for
the button to appear. No external GitHub workflow run has been performed during
local validation.

## 5. Verify the live cache

Uploads use authenticated
`s3://BUCKET_NAME?region=REGION&secret-key=TEMPORARY_KEY_FILE`; consumers use
`https://BUCKET_NAME.s3.REGION.amazonaws.com` without AWS credentials. For example:
`https://my-nix-binary-cache.s3.eu-north-1.amazonaws.com`.
Use the bucket's real region; do not use S3 website endpoints.

After a successful main publication, from the same package revision:

```bash
export AWS_REGION=eu-north-1
export S3_BUCKET=my-nix-binary-cache
cache="https://${S3_BUCKET}.s3.${AWS_REGION}.amazonaws.com"
aws s3 ls "s3://${S3_BUCKET}/" --recursive --profile nix-cache-publisher
curl -f "$cache/nix-cache-info"
hello_path=$(nix eval --raw .#hello.outPath)
store_hash=${hello_path##*/}
store_hash=${store_hash%%-*}
curl -f "$cache/$store_hash.narinfo" -o /tmp/hello.narinfo
cat /tmp/hello.narinfo
grep '^Sig: my-nix-cache-1:' /tmp/hello.narinfo
nar=$(sed -n 's/^URL: //p' /tmp/hello.narinfo)
curl -fI "$cache/$nar"
```

Check `StorePath`, `References`, and `Sig` in the narinfo. Presence of `Sig` alone
is not cryptographic verification: test a signature-checked restore too:

```bash
verify_root=$(mktemp -d)
public_key='my-nix-cache-1:REPLACE_WITH_FULL_PUBLIC_KEY'
nix copy --from "$cache" --to "local?root=$verify_root" \
  --option trusted-public-keys "$public_key" "$hello_path"
nix store verify --store "local?root=$verify_root" --all --sigs-needed 1 \
  --option trusted-public-keys "$public_key"
```

This uses an isolated store and leaves production store paths intact. Remove the
temporary directory after inspection. The HTTP download also exercises runtime
closure availability. The local test suite performs the same kind of restore
against a signed file cache; that does not verify AWS access or public HTTPS.

Confirm unsigned writes are denied using a unique harmless probe object:

```bash
probe="anonymous-write-probe-$(date +%s)"
status=$(curl -sS -o /tmp/nix-cache-probe-response -w '%{http_code}' \
  -X PUT --data 'public writes must be denied' "$cache/$probe")
test "$status" = 403
```

A 2xx status means anonymous writes are enabled: immediately fix bucket policies
and remove the probe through an administrator. The publisher has no delete rights.
A network error is not evidence of access denial.

403 reads can mean account-level public access blocking, a bad policy, or a
missing object when anonymous listing is denied. Check authenticated object
existence with `aws s3api head-object --bucket "$S3_BUCKET" --key KEY --profile
nix-cache-publisher`. A missing `nix-cache-info` means publication has not completed
or the endpoint is wrong. Check region, bucket, main workflow logs, and IAM policy.
Incorrect signatures require matching consumer keys and the exact package revision.

## Costs and maintenance

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
