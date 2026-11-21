#!/usr/bin/env bash
# Disable tracing even when invoked with bash -x, before reading any secrets.
set +x
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
outputs_file=${OUTPUTS_FILE:-.build/store-paths}
for variable in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION S3_BUCKET NIX_CACHE_SIGNING_KEY; do
  if [[ -z ${!variable:-} ]]; then
    echo "Required environment variable is missing: $variable" >&2
    exit 1
  fi
done
for command in nix jq; do
  command -v "$command" >/dev/null || { echo "Required command not found: $command" >&2; exit 1; }
done
# Restrict URLs to AWS bucket names usable with the regional HTTPS endpoint.
if [[ ! $S3_BUCKET =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]; then
  echo "S3_BUCKET must be a 3-63 character AWS bucket name without dots." >&2
  exit 1
fi
if [[ ! $AWS_REGION =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]]; then
  echo "AWS_REGION must be an AWS region name." >&2
  exit 1
fi
if [[ ! -f $outputs_file ]]; then
  echo "Build manifest not found: $outputs_file; run scripts/build-all.sh first." >&2
  exit 1
fi
mapfile -t outputs < "$outputs_file"
if ((${#outputs[@]} == 0)); then
  echo "No store paths to publish." >&2
  exit 0
fi
for output in "${outputs[@]}"; do
  if [[ ! $output =~ ^/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-[^/[:space:]]+$ ]]; then
    echo "Invalid store path in build manifest." >&2
    exit 1
  fi
done
nix path-info "${outputs[@]}" >/dev/null

umask 077
# Use a fixed private location pattern; encode it when embedding it in a URL.
key_file=$(mktemp /tmp/nix-cache-signing.XXXXXXXXXX)
trap 'rm -f -- "$key_file"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s\n' "$NIX_CACHE_SIGNING_KEY" > "$key_file"
unset NIX_CACHE_SIGNING_KEY
key_url=$(jq -rn --arg path "$key_file" '$path | @uri')
# Native copy recursively includes runtime references and skips existing paths.
# Multipart uploads support large NARs without requiring delete permissions.
nix copy --to "s3://${S3_BUCKET}?region=${AWS_REGION}&secret-key=${key_url}&multipart-upload=true" "${outputs[@]}"
