import asyncio
import argparse
import json
import csv
import os
from datetime import datetime, timezone, timedelta
from azure.identity import DefaultAzureCredential
from msgraph import GraphServiceClient

async def main():
    parser = argparse.ArgumentParser(description="Find Entra ID Service Principals that haven't signed in for a long time.")
    parser.add_argument("--days", type=int, default=365, help="Number of days of inactivity to look for (default: 365)")
    parser.add_argument("--output", help="Path to export results as CSV (e.g., unused.csv)")
    args = parser.parse_args()

    print(f"Starting audit for apps unused for over {args.days} days...")

    # Load config
    tenant_id = None
    config_path = "audit_config.json"
    if os.path.exists(config_path):
        try:
            with open(config_path, "r") as f:
                config = json.load(f)
                tenant_id = config.get("tenant_id")
                if tenant_id and "ENTER_YOUR" in tenant_id:
                    tenant_id = None
        except Exception as e:
            print(f"Warning: Failed to read {config_path}: {e}")

    if tenant_id:
        print(f"Using Tenant ID from config: {tenant_id}")
        credential = DefaultAzureCredential(tenant_id=tenant_id)
    else:
        print("Using default tenant from environment/CLI context.")
        credential = DefaultAzureCredential()

    try:
        # User needs AuditLog.Read.All or Directory.Read.All to read signInActivity
        graph_client = GraphServiceClient(credentials=credential, scopes=['https://graph.microsoft.com/.default'])

        print("Fetching Service Principals with signInActivity... (This may take a moment)")
        
        # We need to select signInActivity. 
        # Note: signInActivity requires specific permissions. Use $select to be efficient.
        query_params = {
            "$select": ["appId", "displayName", "signInActivity", "id"]
        }

        # Iterating service principals
        # Using a simple list fetch for MVP. Pagination should be handled for large tenants.
        result = await graph_client.service_principals.get(request_configuration={'query_parameters': query_params})

        unused_apps = []
        today = datetime.now(timezone.utc)
        threshold_date = today - timedelta(days=args.days)

        if result and result.value:
            for sp in result.value:
                last_sign_in = None
                
                # Check signInActivity
                # signInActivity property has lastSignInDateTime
                if sp.sign_in_activity and sp.sign_in_activity.last_sign_in_date_time:
                    last_sign_in = sp.sign_in_activity.last_sign_in_date_time
                
                # Logic:
                # 1. If never signed in (last_sign_in is None) -> It's unused (technically unused forever)
                # 2. If signed in, but before threshold -> Unused for X days
                
                is_unused = False
                days_inactive = -1 # -1 denotes 'Never' in our context logic mostly, but let's handle gracefully

                if last_sign_in is None:
                    is_unused = True
                    last_sign_in_str = "Never"
                    days_inactive_str = "Forever"
                else:
                    if last_sign_in <= threshold_date:
                        is_unused = True
                        last_sign_in_str = str(last_sign_in)
                        days_inactive = (today - last_sign_in).days
                        days_inactive_str = str(days_inactive)
                
                if is_unused:
                    unused_apps.append({
                        "App": sp.display_name or "Unknown",
                        "AppId": sp.app_id,
                        "LastSignIn": last_sign_in_str,
                        "DaysInactive": days_inactive_str,
                        "ObjectId": sp.id
                    })

        # Report
        if not unused_apps:
            print(f"No apps found unused for over {args.days} days.")
        else:
            print(f"\nFound {len(unused_apps)} unused applications:\n")
            print(f"{'App Name':<30} | {'Days Inactive':<15} | {'Last Sign In':<30} | {'App ID'}")
            print("-" * 110)
            for item in unused_apps:
                print(f"{item['App'][:28]:<30} | {item['DaysInactive']:<15} | {item['LastSignIn']:<30} | {item['AppId']}")

        # Export
        if args.output:
            print(f"\nExporting to {args.output}...")
            try:
                with open(args.output, mode='w', newline='', encoding='utf-8') as f:
                    writer = csv.DictWriter(f, fieldnames=["App", "AppId", "LastSignIn", "DaysInactive", "ObjectId"])
                    writer.writeheader()
                    writer.writerows(unused_apps)
                print("Export complete.")
            except Exception as e:
                print(f"Failed to export CSV: {e}")

    except Exception as e:
        print(f"An error occurred: {e}")
        if "403" in str(e):
            print("\n[!] PERMISSION ERROR: Reading 'signInActivity' requires 'AuditLog.Read.All' or 'Directory.Read.All' permissions.")

if __name__ == "__main__":
    asyncio.run(main())
