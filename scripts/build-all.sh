#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
system=${SYSTEM:-x86_64-linux}
outputs_file=${OUTPUTS_FILE:-.build/store-paths}

# A failed run must not leave paths from an earlier build available to publish.
mkdir -p -- "$(dirname -- "$outputs_file")"
rm -f -- "$outputs_file"
for command in nix jq; do
  command -v "$command" >/dev/null || { echo "Required command not found: $command" >&2; exit 1; }
done

work_dir=$(mktemp -d "$(dirname -- "$outputs_file")/.build-all.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT
system_attr=$(jq -rn --arg system "$system" '$system | tojson')
nix eval --json --no-write-lock-file ".#packages.${system_attr}" \
  --apply builtins.attrNames > "$work_dir/packages.json"
jq -r --arg system "$system" \
  '.[] | ".#packages.\($system | tojson).\(. | tojson)^*"' \
  "$work_dir/packages.json" > "$work_dir/installables"
mapfile -t installables < "$work_dir/installables"

if ((${#installables[@]} == 0)); then
  echo "No custom packages for $system." >&2
  : > "$work_dir/paths"
else
  nix build --no-write-lock-file --json --no-link "${installables[@]}" > "$work_dir/build.json"
  # ^* builds every output, including outputs excluded from outputsToInstall.
  jq -er 'if type == "array" and length > 0 then
      [.[].outputs[]] | unique | .[] |
      if type == "string" and startswith("/nix/store/") then .
      else error("Invalid store output path") end
    else error("No build results returned") end' "$work_dir/build.json" > "$work_dir/paths"
fi

mv -- "$work_dir/paths" "$outputs_file"
echo "Store paths written to $outputs_file" >&2
cat -- "$outputs_file"
