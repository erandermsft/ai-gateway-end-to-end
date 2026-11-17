#!/usr/bin/env bash
# Adds a client secret to the Copilot connector app (App A) for the Teams Developer Portal
# OAuth registration. The Microsoft Graph Bicep extension can't create secrets, so this is a
# separate, explicit step. The secret is printed once; store it in the Developer Portal only.
set -euo pipefail

DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-aigw-obo}"
APP_ID="$(az deployment sub show --name "$DEPLOYMENT_NAME" \
  --query "properties.outputs.copilotConnector.value.clientId" -o tsv)"

if [[ -z "$APP_ID" ]]; then
  echo "No Copilot connector app in deployment '$DEPLOYMENT_NAME' (enableCopilotConnector = false?)." >&2
  exit 1
fi

az ad app credential reset --id "$APP_ID" --append --display-name "teams-developer-portal-oauth" \
  --years 1 --query password -o tsv
