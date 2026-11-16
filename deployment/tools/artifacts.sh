#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: artifacts.sh versions
       artifacts.sh get VERSION ASSET OUTPUT_FILE
       artifacts.sh copy DESTINATION_REPOSITORY VERSION [VERSION ...]
       artifacts.sh status STATUS VERSION [VERSION ...]
       artifacts.sh delete VERSION [VERSION ...]

Required environment: ARTIFACT_REGION, ARTIFACT_DOMAIN, ARTIFACT_REPOSITORY,
ARTIFACT_FORMAT, APP_PACKAGE. Maven, Swift and generic packages require ARTIFACT_NAMESPACE.
Batch copy/status/delete operations also require jq and report partial failures.
Optional: AWS_ACCOUNT_ID for a domain owned by another account.
Copy, status and delete act only on the explicitly supplied versions.
USAGE
}

operation="${1:-}"
if [[ "$operation" == --help || "$operation" == -h ]]; then usage; exit 0; fi
if [[ -z "$operation" ]]; then usage >&2; exit 2; fi
shift
case "$operation" in
  versions) [[ $# -eq 0 ]] || { usage >&2; exit 2; } ;;
  get) [[ $# -eq 3 ]] || { usage >&2; exit 2; } ;;
  copy|status) [[ $# -ge 2 ]] || { usage >&2; exit 2; } ;;
  delete) [[ $# -ge 1 ]] || { usage >&2; exit 2; } ;;
  *) usage >&2; exit 2 ;;
esac
for setting in ARTIFACT_REGION ARTIFACT_DOMAIN ARTIFACT_REPOSITORY ARTIFACT_FORMAT APP_PACKAGE; do
  if [[ -z "${!setting:-}" ]]; then echo "Set $setting." >&2; exit 2; fi
done
if [[ "$ARTIFACT_FORMAT" =~ ^(maven|swift|generic)$ && -z "${ARTIFACT_NAMESPACE:-}" ]]; then
  echo "Set ARTIFACT_NAMESPACE for $ARTIFACT_FORMAT packages." >&2
  exit 2
fi
common=(--region="$ARTIFACT_REGION" --domain="$ARTIFACT_DOMAIN" --format="$ARTIFACT_FORMAT" --package="$APP_PACKAGE")
if [[ -n "${AWS_ACCOUNT_ID:-}" ]]; then common+=(--domain-owner="$AWS_ACCOUNT_ID"); fi
if [[ -n "${ARTIFACT_NAMESPACE:-}" ]]; then common+=(--namespace="$ARTIFACT_NAMESPACE"); fi
case "$operation" in
  versions)
    aws codeartifact list-package-versions "${common[@]}" --repository="$ARTIFACT_REPOSITORY"
    exit 0
    ;;
  get)
    output_file="$3"
    if [[ "$output_file" == -* ]]; then output_file="./$output_file"; fi
    aws codeartifact get-package-version-asset "${common[@]}" --repository="$ARTIFACT_REPOSITORY" --package-version="$1" --asset="$2" "$output_file"
    exit 0
    ;;
  copy)
    destination="$1"; shift
    request=(copy-package-versions "${common[@]}" --source-repository="$ARTIFACT_REPOSITORY" --destination-repository="$destination")
    ;;
  status)
    status="$1"; shift
    request=(update-package-versions-status "${common[@]}" --repository="$ARTIFACT_REPOSITORY" --target-status="$status")
    ;;
  delete)
    request=(delete-package-versions "${common[@]}" --repository="$ARTIFACT_REPOSITORY")
    ;;
esac

command -v jq >/dev/null || { echo "Install jq before running package batch operations." >&2; exit 2; }
# A version that resembles a CLI option must remain a version, not change the request.
versions_json=$(jq -cn --args '$ARGS.positional' -- "$@")
response=$(aws codeartifact "${request[@]}" --versions "$versions_json" --output json --no-cli-pager)
printf '%s\n' "$response"
# HTTP success does not imply that every requested package operation succeeded.
if ! jq -e --argjson requested "$versions_json" '
  . as $response |
  type == "object" and
  (.successfulVersions | type == "object") and
  ((.failedVersions // {}) | type == "object" and length == 0) and
  all($requested[]; . as $version | ($response.successfulVersions[$version] | type) == "object")
' <<< "$response" >/dev/null; then
  echo "Package operation did not report complete success; inspect the response." >&2
  exit 1
fi
