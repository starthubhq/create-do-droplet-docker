#!/bin/sh
set -euo pipefail

# Read entire JSON payload from stdin (non-blocking if nothing piped)
INPUT="$(cat || true)"

# ---------------------------
# Param extraction (precedence)
# 1) stdin.params.*
# 2) top-level keys (stdin.*)
# 3) environment variables
# ---------------------------

# Auth
do_access_token="$(
  printf '%s' "${INPUT}" \
  | jq -r '(.params.do_access_token // .do_access_token // env.do_access_token // empty)'
)"

# Required
droplet_name="$(
  printf '%s' "${INPUT}" \
  | jq -r '(.params.droplet_name // .droplet_name // env.droplet_name // empty)'
)"

# Optional with sane defaults
region="$(
  printf '%s' "${INPUT}" \
  | jq -r '(.params.region // .region // env.region // "fra1")'
)"
size="$(
  printf '%s' "${INPUT}" \
  | jq -r '(.params.size // .size // env.size // "s-1vcpu-1gb")'
)"
image="$(
  printf '%s' "${INPUT}" \
  | jq -r '(.params.image // .image // env.image // "ubuntu-22-04-x64")'
)"

# Optional toggles (normalize to literal true/false strings)
backups="$(
  printf '%s' "${INPUT}" \
  | jq -r '(.params.backups // .backups // env.backups // false)
           | if type=="boolean" then . else ((tostring|ascii_downcase)=="true") end'
)"
ipv6="$(
  printf '%s' "${INPUT}" \
  | jq -r '(.params.ipv6 // .ipv6 // env.ipv6 // true)
           | if type=="boolean" then . else ((tostring|ascii_downcase)=="true") end'
)"
monitoring="$(
  printf '%s' "${INPUT}" \
  | jq -r '(.params.monitoring // .monitoring // env.monitoring // true)
           | if type=="boolean" then . else ((tostring|ascii_downcase)=="true") end'
)"

# Optional extras
vpc_uuid="$(
  printf '%s' "${INPUT}" \
  | jq -r '(.params.vpc_uuid // .vpc_uuid // env.vpc_uuid // empty)'
)"
user_data="$(
  printf '%s' "${INPUT}" \
  | jq -r '(.params.user_data // .user_data // env.user_data // empty)'
)"

# SSH keys (accepts array in JSON; or comma-separated env string)
ssh_keys_json="$(
  keys="$(printf '%s' "${INPUT}" | jq -c '(.params.ssh_keys // .ssh_keys // empty)')" || true
  if [ -n "${keys:-}" ] && [ "${keys}" != "null" ]; then
    printf '%s' "${keys}"
  else
    if [ -n "${ssh_keys:-}" ]; then
      printf '%s' "${ssh_keys}" | awk -F, '{
        printf("["); for (i=1;i<=NF;i++){ gsub(/^ +| +$/,"",$i); printf("%s\"%s\"", (i>1?",":""), $i) } printf("]");
      }'
    else
      printf '[]'
    fi
  fi
)"

# Tags (accept array in JSON; or comma-separated env)
tags_json="$(
  tjson="$(printf '%s' "${INPUT}" | jq -c '(.params.tags // .tags // empty)')" || true
  if [ -n "${tjson:-}" ] && [ "${tjson}" != "null" ]; then
    printf '%s' "${tjson}"
  else
    if [ -n "${tags:-}" ]; then
      printf '%s' "${tags}" | awk -F, '{
        printf("["); for (i=1;i<=NF;i++){ gsub(/^ +| +$/,"",$i); printf("%s\"%s\"", (i>1?",":""), $i) } printf("]");
      }'
    else
      printf '["starthub"]'
    fi
  fi
)"

# ---------------------------
# Validation
# ---------------------------
[ -n "${do_access_token:-}" ] || { echo "Error: do_access_token missing (stdin.params.do_access_token or env.do_access_token)" >&2; exit 1; }
[ -n "${droplet_name:-}" ]    || { echo "Error: droplet_name missing (stdin.params.droplet_name or env.droplet_name)" >&2; exit 1; }
[ -n "${region:-}" ]          || { echo "Error: region missing/empty" >&2; exit 1; }
[ -n "${size:-}" ]            || { echo "Error: size missing/empty" >&2; exit 1; }
[ -n "${image:-}" ]           || { echo "Error: image missing/empty" >&2; exit 1; }

echo "Creating DigitalOcean Droplet: ${droplet_name} (region=${region}, size=${size}, image=${image})" >&2

# ---------------------------
# Build JSON payload safely
# ---------------------------
payload="$(
  jq -nc \
    --arg name        "$droplet_name" \
    --arg region      "$region" \
    --arg size        "$size" \
    --arg image       "$image" \
    --arg vpc_uuid    "$vpc_uuid" \
    --arg user_data   "$user_data" \
    --argjson sshkeys "$ssh_keys_json" \
    --argjson tags    "$tags_json" \
    --argjson backups "$backups" \
    --argjson ipv6    "$ipv6" \
    --argjson monit   "$monitoring" \
    '
    {
      name: $name,
      region: $region,
      size: $size,
      image: $image,
      ssh_keys: ($sshkeys // []),
      backups: $backups,
      ipv6: $ipv6,
      monitoring: $monit,
      tags: ($tags // [])
    }
    +
    (if ($vpc_uuid|length) > 0 then { vpc_uuid: $vpc_uuid } else {} end)
    +
    (if ($user_data|length) > 0 then { user_data: $user_data } else {} end)
    '
)"

# ---------------------------
# API call
# ---------------------------
resp="$(
  curl -sS -f -X POST "https://api.digitalocean.com/v2/droplets" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${do_access_token}" \
    -d "${payload}"
)"; rc=$?

if [ $rc -ne 0 ]; then
  echo "DigitalOcean API call failed (HTTP non-2xx). Raw response below:" >&2
  echo "$resp" | jq . >&2 || echo "$resp" >&2
  exit 1
fi

# ---------------------------
# Parse droplet fields
# ---------------------------
droplet_id="$(printf '%s' "$resp" | jq -r '.droplet.id // empty')"
[ -n "$droplet_id" ] || { echo "Error: could not parse .droplet.id from response" >&2; echo "$resp" | jq . >&2; exit 1; }

droplet_name_out="$(printf '%s' "$resp" | jq -r '.droplet.name // empty')"
region_out="$(printf '%s' "$resp" | jq -r '.droplet.region.slug // empty')"
size_out="$(printf '%s' "$resp" | jq -r '.droplet.size_slug // empty')"
image_out="$(printf '%s' "$resp" | jq -r '(.droplet.image.slug // .droplet.image.id // empty)')"

# Emit canonical state patch for the runner to merge
name_json="$(jq -Rn --arg n "$droplet_name_out" '$n')"
region_json="$(jq -Rn --arg r "$region_out" '$r')"
size_json="$(jq -Rn --arg s "$size_out" '$s')"
image_json="$(jq -Rn --arg i "$image_out" '$i')"

echo "::starthub:state::{\"droplet\":{\"id\":${droplet_id},\"name\":${name_json},\"region\":${region_json},\"size\":${size_json},\"image\":${image_json}}}"

# Pretty log to stderr without interfering with the marker line
{
  echo "Created droplet:"
  printf '%s\n' "$resp" | jq .
} >&2
