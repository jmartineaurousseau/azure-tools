#!/usr/bin/env bash
# Create Azure DevOps service connections (Azure Resource Manager, Workload Identity
# federation - manual) backed by the user-assigned managed identities created in
# azure-cli.sh, then add the matching federated credential on each identity.
# Intended to be run in Azure Cloud Shell (bash). Run azure-cli.sh first.
#
# Prerequisites:
#   - The caller can create service connections in the DevOps project and
#     federated credentials on the identities.
#   - The identities have the Azure RBAC roles they need on the target scope
#     (role assignment is NOT done here).

set -euo pipefail

# --- Variables ---------------------------------------------------------------
ADO_ORG_URL="https://dev.azure.com/<organization>"
ADO_PROJECT=""

# Subscription where the identities live (the one azure-cli.sh ran against);
# leave empty to use the current default subscription
IDENTITY_SUBSCRIPTION_ID=""

# Target subscription for each service connection
SUBSCRIPTION_A1=""
SUBSCRIPTION_A2=""
SUBSCRIPTION_A3=""
SUBSCRIPTION_B1=""

RESOURCE_GROUP_A=""
RESOURCE_GROUP_B=""

# Must match azure-cli.sh
IDENTITY_A1="uami-a1"
IDENTITY_A2="uami-a2"
IDENTITY_A3="uami-a3"
IDENTITY_B1="uami-b1"

# Entries are "<service connection name>|<identity name>|<identity resource group>|<target subscription id>"
# Each connection uses its own identity (client id) and targets its own subscription.
CONNECTIONS=(
  "sc-a1|$IDENTITY_A1|$RESOURCE_GROUP_A|$SUBSCRIPTION_A1"
  "sc-a2|$IDENTITY_A2|$RESOURCE_GROUP_A|$SUBSCRIPTION_A2"
  "sc-a3|$IDENTITY_A3|$RESOURCE_GROUP_A|$SUBSCRIPTION_A3"
  "sc-b1|$IDENTITY_B1|$RESOURCE_GROUP_B|$SUBSCRIPTION_B1"
)

# --- Setup -------------------------------------------------------------------
if [[ -n "$IDENTITY_SUBSCRIPTION_ID" ]]; then
  az account set --subscription "$IDENTITY_SUBSCRIPTION_ID"
fi

az extension add --name azure-devops --only-show-errors
az devops configure --defaults organization="$ADO_ORG_URL" project="$ADO_PROJECT"

IDENTITY_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
PROJECT_ID=$(az devops project show --project "$ADO_PROJECT" --query id -o tsv)

echo "Identity subscription: $IDENTITY_SUBSCRIPTION_ID"
echo "DevOps project: $ADO_PROJECT ($PROJECT_ID)"

# --- Service connections -----------------------------------------------------
for entry in "${CONNECTIONS[@]}"; do
  IFS='|' read -r sc_name identity_name identity_rg target_sub_id <<< "$entry"

  echo
  echo "=== $sc_name  <-  $identity_name ($identity_rg) ==="

  client_id=$(az identity show --subscription "$IDENTITY_SUBSCRIPTION_ID" --name "$identity_name" --resource-group "$identity_rg" --query clientId -o tsv)
  target_sub_name=$(az account show --subscription "$target_sub_id" --query name -o tsv)
  echo "Client id: $client_id | Target subscription: $target_sub_name ($target_sub_id)"

  config_file=$(mktemp)
  cat > "$config_file" <<EOF
{
  "name": "$sc_name",
  "type": "azurerm",
  "url": "https://management.azure.com/",
  "authorization": {
    "scheme": "WorkloadIdentityFederation",
    "parameters": {
      "serviceprincipalid": "$client_id",
      "tenantid": "$TENANT_ID"
    }
  },
  "data": {
    "environment": "AzureCloud",
    "scopeLevel": "Subscription",
    "subscriptionId": "$target_sub_id",
    "subscriptionName": "$target_sub_name",
    "creationMode": "Manual"
  },
  "isShared": false,
  "isReady": true,
  "serviceEndpointProjectReferences": [
    {
      "projectReference": { "id": "$PROJECT_ID", "name": "$ADO_PROJECT" },
      "name": "$sc_name"
    }
  ]
}
EOF

  endpoint_json=$(az devops service-endpoint create --service-endpoint-configuration "$config_file" -o json)
  rm -f "$config_file"

  # Azure DevOps generates the issuer and subject for the connection.
  issuer=$(echo "$endpoint_json" | jq -r '.authorization.parameters.workloadIdentityFederationIssuer')
  subject=$(echo "$endpoint_json" | jq -r '.authorization.parameters.workloadIdentityFederationSubject')

  if [[ -z "$issuer" || "$issuer" == "null" || -z "$subject" || "$subject" == "null" ]]; then
    echo "ERROR: issuer/subject not returned for $sc_name. Copy them from the service" >&2
    echo "connection in Azure DevOps and create the federated credential manually." >&2
    exit 1
  fi

  echo "Issuer:  $issuer"
  echo "Subject: $subject"

  # Federated credential on the managed identity so the connection can authenticate.
  az identity federated-credential create \
    --subscription "$IDENTITY_SUBSCRIPTION_ID" \
    --name "$sc_name" \
    --identity-name "$identity_name" \
    --resource-group "$identity_rg" \
    --issuer "$issuer" \
    --subject "$subject" \
    --audiences "api://AzureADTokenExchange" \
    -o table
done
