#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then echo "Usage: $0 REPOSITORY [REPOSITORY ...]" >&2; exit 2; fi
REPOSITORIES=("$@")
REGION="${AWS_REGION:?Set AWS_REGION}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "ACCOUNT: $ACCOUNT_ID"
failed=0
for REPO in "${REPOSITORIES[@]}"; do
  echo "Creating ECR repository: $REPO in region $REGION"
  if result=$(aws ecr create-repository \
    --repository-name="$REPO" \
    --region="$REGION" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 \
    --output text 2>&1); then
    printf '%s\n' "$result"
  elif [[ "$result" == *"(RepositoryAlreadyExistsException)"* ]]; then
    echo "Repository $REPO already exists."
  else
    printf '%s\n' "$result" >&2
    failed=1
  fi
done
exit "$failed"
