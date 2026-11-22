#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: verify-cache.sh --cache-url URL --bucket NAME --region REGION \
  --public-key NAME:KEY [--store-path /nix/store/... ] [--aws-profile PROFILE] \
  [--check-anonymous-write]

Checks authenticated object listing, anonymous cache metadata, the selected
store path's signed narinfo, its referenced NAR, and signature-checked restore
into an isolated temporary store. Store path defaults to this flake's .#hello.
The anonymous PUT probe is opt-in; if accepted, it leaves a probe object for
an administrator to remove.
USAGE
}

cache_url=
bucket=
region=
public_key=
store_path=
aws_profile=
check_anonymous_write=false
while (($#)); do
  case $1 in
    --cache-url) (($# >= 2)) || { usage >&2; exit 2; }; cache_url=$2; shift 2 ;;
    --bucket) (($# >= 2)) || { usage >&2; exit 2; }; bucket=$2; shift 2 ;;
    --region) (($# >= 2)) || { usage >&2; exit 2; }; region=$2; shift 2 ;;
    --public-key) (($# >= 2)) || { usage >&2; exit 2; }; public_key=$2; shift 2 ;;
    --store-path) (($# >= 2)) || { usage >&2; exit 2; }; store_path=$2; shift 2 ;;
    --aws-profile) (($# >= 2)) || { usage >&2; exit 2; }; aws_profile=$2; shift 2 ;;
    --check-anonymous-write) check_anonymous_write=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
for pair in cache_url bucket region public_key; do
  [[ -n ${!pair} ]] || { echo "Missing required option: --${pair//_/-}" >&2; usage >&2; exit 2; }
done
for command in aws curl jq nix; do
  command -v "$command" >/dev/null || { echo "Required command not found: $command" >&2; exit 1; }
done
[[ $cache_url == "https://${bucket}.s3.${region}.amazonaws.com" ]] || {
  echo "--cache-url must match https://${bucket}.s3.${region}.amazonaws.com" >&2; exit 2;
}
[[ $public_key == *:* ]] || { echo "--public-key must include the Nix key name and colon." >&2; exit 2; }
if [[ -z $store_path ]]; then
  repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
  store_path=$(nix eval --raw --no-write-lock-file "$repo_root#hello.outPath")
fi
[[ $store_path =~ ^/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-[^/[:space:]]+$ ]] || {
  echo "Invalid store path: $store_path" >&2; exit 2;
}

aws_args=()
[[ -z $aws_profile ]] || aws_args+=(--profile "$aws_profile")
echo "Authenticated listing: s3://${bucket}/"
aws s3 ls "s3://${bucket}/" --recursive "${aws_args[@]}"
echo "Anonymous cache metadata: ${cache_url}/nix-cache-info"
curl --fail --show-error --silent "${cache_url}/nix-cache-info"
printf '\n'
store_hash=${store_path##*/}
store_hash=${store_hash%%-*}
narinfo_file=$(mktemp)
verify_root=$(mktemp -d)
probe_body=$(mktemp)
trap 'rm -f -- "$narinfo_file" "$probe_body"; rm -rf -- "$verify_root"' EXIT
curl --fail --show-error --silent "${cache_url}/${store_hash}.narinfo" -o "$narinfo_file"
grep -Fqx "StorePath: ${store_path}" "$narinfo_file" || { echo "narinfo StorePath mismatch" >&2; exit 1; }
expected_key_name=${public_key%%:*}
grep -Fq "Sig: ${expected_key_name}:" "$narinfo_file" || { echo "Expected Nix signature not found in narinfo" >&2; exit 1; }
printf '%s\n' 'narinfo StorePath, References, and signature:'
sed -n -e '/^StorePath:/p' -e '/^References:/p' -e '/^Sig:/p' -e '/^URL:/p' "$narinfo_file"
nar=$(sed -n 's/^URL: //p' "$narinfo_file")
[[ -n $nar ]] || { echo "narinfo has no NAR URL" >&2; exit 1; }
curl --fail --show-error --silent --head "${cache_url}/${nar}" >/dev/null
echo "Referenced NAR is downloadable: ${nar}"
nix copy --from "$cache_url" --to "local?root=${verify_root}" \
  --option trusted-public-keys "$public_key" "$store_path"
nix store verify --store "local?root=${verify_root}" --all --sigs-needed 1 \
  --option trusted-public-keys "$public_key"
echo "Nix signature verification passed in isolated store: ${verify_root}"

if $check_anonymous_write; then
  probe="anonymous-write-probe-$(date +%s)-$$"
  status=$(curl --silent --show-error --output "$probe_body" --write-out '%{http_code}' \
    --request PUT --data 'public writes must be denied' "${cache_url}/${probe}") || {
      echo "Anonymous write probe had a network error; outcome is inconclusive." >&2; exit 1;
    }
  if [[ $status == 403 ]]; then
    echo "Anonymous upload denied (HTTP 403)."
  elif [[ $status == 2* ]]; then
    echo "SECURITY FAILURE: anonymous upload accepted (HTTP ${status}); remove s3://${bucket}/${probe} with an administrator." >&2
    exit 1
  else
    echo "Anonymous upload probe returned HTTP ${status}; expected 403, outcome is inconclusive." >&2
    exit 1
  fi
fi
