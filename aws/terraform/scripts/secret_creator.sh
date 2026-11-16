#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 2 ]]; then
  echo "Usage: secret_creator.sh SECRET_NAME TEXT_FILE (requires AWS_REGION)" >&2
  exit 2
fi
: "${AWS_REGION:?Set AWS_REGION}"
secret_name="$1"
secret_file="$2"
[[ -s "$secret_file" ]] || { echo "Secret file is missing or empty." >&2; exit 2; }
if aws secretsmanager describe-secret --region="$AWS_REGION" --secret-id="$secret_name" >/dev/null 2>&1; then
  aws secretsmanager put-secret-value --region="$AWS_REGION" --secret-id="$secret_name" --secret-string="file://$secret_file"
else
  aws secretsmanager create-secret --region="$AWS_REGION" --name="$secret_name" --secret-string="file://$secret_file"
fi
