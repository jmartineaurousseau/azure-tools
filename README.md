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
    "tenant_id": "your-tenant-id-here"
}
```

## Usage

### Local Execution (Interactive)

1. Log in to Azure CLI:
   ```bash
   az login --tenant <your-tenant-id>
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

## Permissions

To run this tool, the identity (User or Service Principal) requires **Microsoft Graph** permissions.

### `entra_app_secret_audit.py` (Secret Audit)
- **Permission**: `Application.Read.All`
- **Type**: Delegated or Application

### `entra_unused_apps.py` (Unused Apps)
- **Permission**: `AuditLog.Read.All` OR `Directory.Read.All`
- **Type**: Delegated or Application
- **Note**: Reading `signInActivity` requires these higher-privilege permissions. `Application.Read.All` is **not** sufficient.

### Delegated (User Context - `az login`)
- **Permission**: `Application.Read.All`
- **Type**: Delegated
- **Description**: Allows the user to read all applications in the directory.
- *Note: Admin consent might be required depending on tenant settings.*

### Application (Service Principal / Managed Identity)
- **Permission**: `Application.Read.All`
- **Type**: Application
- **Description**: Allows the app to read all applications without a signed-in user.

## Deployment (Future)

### Azure Functions / Automation Account
This script is designed to use `DefaultAzureCredential`. When deployed to Azure resources:
1. Enable **System Assigned Managed Identity** on the Function App or Automation Account.
2. Grant the Managed Identity the `Application.Read.All` permission in Microsoft Graph:
   ```powershell
   # Example PowerShell to grant permission
   $TenantId = "your-tenant-id"
   $AppId = "your-managed-identity-object-id" # OR output of (Get-AzFunctionApp).Identity.PrincipalId
   $GraphAppId = "00000003-0000-0000-c000-000000000000" # Microsoft Graph
   
   # ... (Requires MSGraph PowerShell permissions to assign roles)
   ```
