# Entra ID App Secret Audit Tool

This tool audits your Microsoft Entra ID (formerly Azure AD) tenant for Application Registrations with secrets or certificates that are about to expire. It can also export the findings to a CSV file.

## Prerequisites

- Python 3.7+
- An Azure account with permissions to read applications.

## Installation

1. Clone this repository.
2. Install dependencies:
   ```bash
   pip install -r requirements.txt
   ```

## Configuration (Optional)

You can create a file named `audit_config.json` in the same directory to specify your Tenant ID. This is useful if you have access to multiple tenants or want to ensure the script runs against a specific one.

**audit_config.json**:
```json
{
    "tenant_id": "your-tenant-id-here",
    "subscription_id": "your-subscription-id-here"
}
```

## Usage

### Local Execution (Interactive)

1. Log in to Azure CLI:
   ```bash
   az login --tenant <your-tenant-id>
   az login --identity # if using a managed identity
   ```
   *Note: Ensure the account you log in with has the necessary permissions (see below).*

2. Run the script:
   ```bash
   # Default check (30 days)
   python entra_app_secret_audit.py

   # Custom threshold (e.g., 60 days)
   python entra_app_secret_audit.py --days 60

   # Export results to CSV
   python entra_app_secret_audit.py --output results.csv
   ```

### Find Unused Applications

1. Run the script to find Service Principals that haven't signed in for 365 days (default):
   ```bash
   python entra_unused_apps.py
   ```

2. Custom lookback period (e.g., 90 days) and CSV export:
   ```bash
   python entra_unused_apps.py --days 90 --output unused.csv
   ```

### Find Orphaned Applications

Identify applications with **no owners** or where **all owners are disabled/deleted**.

1. Run the audit:
   ```bash
   python entra_orphaned_apps.py
   ```

2. Export results:
   ```bash
   python entra_orphaned_apps.py --output orphaned.csv
   ```



### Report New Defender for Cloud Items

Find new Security Recommendations and Attack Paths that appeared in the last X days (default: 7).

1. Run the report:
   ```bash
   python defender_new_items.py
   ```

2. Custom lookback and export:
   ```bash
   python defender_new_items.py --days 14 --output defender_report.csv
   ```

## Permissions

To run this tool, the identity (User or Service Principal) requires **Microsoft Graph** permissions and **Azure RBAC** permissions.

### `entra_app_secret_audit.py` (Secret Audit)
- **Permission**: `Application.Read.All`
- **Type**: Delegated or Application

### `entra_unused_apps.py` (Unused Apps)
- **Permission**: `AuditLog.Read.All` OR `Directory.Read.All`
- **Type**: Delegated or Application

### `entra_orphaned_apps.py` (Orphaned Apps)
- **Permission**: `Application.Read.All` AND `User.Read.All` (or `Directory.Read.All`)
- **Type**: Delegated or Application

### `defender_new_items.py` (Defender Report)
- **Role**: `Security Reader` (Azure RBAC) on the Subscription(s).
- **Library**: Requires `azure-mgmt-resourcegraph`.
  ```bash
  pip install azure-mgmt-resourcegraph
  ```

### Delegated (User Context - `az login`)
- **Permission**: `Application.Read.All`
- **Type**: Delegated
- **Description**: Allows the user to read all applications in the directory.
- *Note: Admin consent might be required depending on tenant settings.*

### Application (Service Principal / Managed Identity)
- **Permission**: `Application.Read.All`
- **Type**: Application
- **Description**: Allows the app to read all applications without a signed-in user.

## Deployment

You can deploy this tool as an Azure Function App using the provided Bicep templates.

### Prerequisites

- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
- [Azure Functions Core Tools](https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local?tabs=windows%2Cisolated-process%2Cnode-v4%2Cpython-v2%2Chttp-trigger%2Ccontainer-apps&pivots=programming-language-python#install-the-azure-functions-core-tools)
- PowerShell (to run the deployment script)

### Deploying to Azure

1.  Login to Azure:
    ```bash
    az login
    ```

2.  Configure your deployment:
    Edit `bicep/config.json` with your desired values:
    ```json
    {
        "subscriptionId": "your-subscription-id",
        "resourceGroupName": "rg-azure-tools",
        "location": "canadacentral",
        "functionAppName": "func-azure-tools-001",
        "storageAccountName": "staztools001"
    }
    ```

3.  Run the deployment script:
    ```powershell
    ./bicep/deploy.ps1
    ```
    This script will:
    - Read configuration from `bicep/config.json`.
    - Create the Resource Group (if it doesn't exist).
    - Deploy the infrastructure (Function App, Storage, App Service Plan, App Insights).
    - Publish the Python code to the Function App.
    - Output the name of the deployed Function App.

### Permissions (Post-Deployment)

After deployment, the Function App's System Assigned Managed Identity needs permissions.
You must grant the following Graph API permissions to the Managed Identity:
- `Application.Read.All`
- `AuditLog.Read.All` (or `Directory.Read.All`)
- `User.Read.All`

You can do this via PowerShell (AzureAD / Microsoft.Graph modules) or manually in the Portal (Enterprise Applications -> [Function App Name] -> Permissions).

For `defender_new_items`, grant the Managed Identity the **Security Reader** role on the Subscription.

### Local Development

1.  Create `local.settings.json` (optional, for local testing):
    ```json
    {
      "IsEncrypted": false,
      "Values": {
        "AzureWebJobsStorage": "UseDevelopmentStorage=true",
        "FUNCTIONS_WORKER_RUNTIME": "python"
      }
    }
    ```
2.  Run locally:
    ```bash
    func start
    ```

## Deployment Script

To deploy the infrastructure and function app code, use the provided PowerShell script:

```powershell
.\bicep\deploy.ps1
```

This script will:
1.  Check if **Azure Functions Core Tools** (`func`) is installed.
    -   If not found, it attempts to install it automatically via `winget`.
2.  Deploy the Bicep infrastructure (Resource Group, Storage Account, Function App).
3.  Publish the Python function code to the deployed Function App.

**Configuration:**
Ensure you have a `bicep/bicep-config.json` file with your environment details (subscription, resource group, etc.).
