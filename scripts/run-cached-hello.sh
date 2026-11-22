#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: run-cached-hello.sh --cache-url URL --public-key NAME:KEY

Checks that this repository's .#hello output is present in the public cache with
a signature from NAME, asks Nix to build using that cache as an additional
substituter, then runs the resulting hello.
USAGE
}

cache_url=
public_key=
while (($#)); do
  case $1 in
    --cache-url) (($# >= 2)) || { usage >&2; exit 2; }; cache_url=$2; shift 2 ;;
    --public-key) (($# >= 2)) || { usage >&2; exit 2; }; public_key=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n $cache_url ]] || { echo "Missing required option: --cache-url" >&2; usage >&2; exit 2; }
[[ -n $public_key && $public_key == *:* ]] || { echo "--public-key must include the Nix key name and colon." >&2; usage >&2; exit 2; }
command -v nix >/dev/null || { echo "Required command not found: nix" >&2; exit 1; }
[[ $cache_url == https://* ]] || { echo "--cache-url must use HTTPS." >&2; exit 2; }

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
store_path=$(nix eval --raw --no-write-lock-file .#hello.outPath)
echo "Checking signed cache entry for ${store_path}"
nix path-info --store "$cache_url" --sigs "$store_path" >/dev/null
key_name=${public_key%%:*}
store_hash=${store_path##*/}
store_hash=${store_hash%%-*}
narinfo_url="${cache_url%/}/${store_hash}.narinfo"
narinfo=$(curl --fail --show-error --silent "$narinfo_url")
grep -Fq "Sig: ${key_name}:" <<< "$narinfo" || {
  echo "Cache entry has no signature from ${key_name}." >&2; exit 1;
}

# Add cache trust/settings without replacing the machine's configured caches or keys.
hello_path=$(nix build --no-link --print-out-paths .#hello \
  --option extra-substituters "$cache_url" \
  --option extra-trusted-public-keys "$public_key")
printf '%s\n' "$hello_path"
"$hello_path/bin/hello"
