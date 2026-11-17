#!/usr/bin/env bash
# Creates the tenant service principal for a (first-party) app ID if it doesn't exist yet.
# Idempotent; intentionally has no destroy counterpart.
set -euo pipefail

APP_ID="${1:?usage: ensure-service-principal.sh <app-id>}"

if az ad sp show --id "$APP_ID" --query id -o tsv >/dev/null 2>&1; then
  echo "Service principal for $APP_ID already exists."
  exit 0
fi

echo "Creating service principal for $APP_ID ..."
az ad sp create --id "$APP_ID" --query id -o tsv

for _ in $(seq 1 30); do
  if az ad sp show --id "$APP_ID" --query id -o tsv >/dev/null 2>&1; then
    exit 0
  fi
  sleep 5
done

echo "Service principal for $APP_ID was created but isn't readable yet." >&2
exit 1
