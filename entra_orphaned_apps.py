import asyncio
import argparse
import json
import csv
import os
from azure.identity import DefaultAzureCredential
from msgraph import GraphServiceClient
from msgraph.generated.models.user import User
from msgraph.generated.models.service_principal import ServicePrincipal

async def main():
    parser = argparse.ArgumentParser(description="Find Orphaned Entra ID App Registrations (No owners or disabled owners).")
    parser.add_argument("--output", help="Path to export results as CSV (e.g., orphaned.csv)")
    args = parser.parse_args()

    print("Starting audit for orphaned applications...")

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
            pass

    if tenant_id:
        print(f"Using Tenant ID from config: {tenant_id}")
        credential = DefaultAzureCredential(tenant_id=tenant_id)
    else:
        print("Using default tenant from environment/CLI context.")
        credential = DefaultAzureCredential()

    try:
        # We need Application.Read.All (for apps) and User.Read.All (to check accountEnabled)
        graph_client = GraphServiceClient(credentials=credential, scopes=['https://graph.microsoft.com/.default'])

        print("Fetching Applications with Owners... (This may take a while)")

        # Select relevant fields and expand owners
        # Note: We need to specify $select for the app, AND $select for the owners if possible to be efficient.
        # However, Python SDK expand usage can be tricky.
        # Let's try basic expand first.
        
        # In OData: /applications?$expand=owners($select=id,displayName,userPrincipalName,accountEnabled)
        # The python SDK builder pattern:
        # request_configuration = ApplicationsRequestBuilder.ApplicationsRequestBuilderGetRequestConfiguration(
        #     query_parameters = ApplicationsRequestBuilder.ApplicationsRequestBuilderGetQueryParameters(
        #         select = ["id", "appId", "displayName"],
        #         expand = ["owners"]
        #     )
        # )
        
        query_params = {
            "$select": ["id", "appId", "displayName"],
            "$expand": ["owners"]
        }

        # Dealing with pagination manually or letting SDK handle it?
        # SDK default get() handles pages? No, usually returns a collection object we need to iterate.
        
        result = await graph_client.applications.get(request_configuration={'query_parameters': query_params})

        orphaned_apps = []

        if result and result.value:
            for app in result.value:
                owners = app.owners
                
                is_orphaned = False
                orphan_reason = ""
                owner_names = []

                if not owners:
                    is_orphaned = True
                    orphan_reason = "No Owners"
                else:
                    # Check if all owners are disabled
                    # owners is a list of DirectoryObject. We need to check if they are Users and if they are enabled.
                    # Note: Owners can be ServicePrincipals too.
                    
                    all_disabled = True
                    has_active_owner = False
                    
                    for owner in owners:
                        # Collect name for report
                        d_name = getattr(owner, 'display_name', 'Unknown')
                        owner_names.append(d_name)

                        # Check status
                        # account_enabled is a property of User (and ServicePrincipal). 
                        # DirectoryObject doesn't have it by default unless casted/typed?
                        # The SDK uses OData inheritance.
                        
                        is_enabled = False
                        
                        # Use attribute check for safety
                        if hasattr(owner, 'account_enabled'):
                             # Explicit check: account_enabled is boolean
                             if owner.account_enabled is True:
                                 is_enabled = True
                        else:
                            # If we can't read account_enabled (e.g. permission issue or not a property on this object type), 
                            # we have to assume valid or at least NOT definitively disabled.
                            # However, 'owners' endpoint returns DirectoryObject. 
                            # If we didn't $select/expand correctly, we might miss data.
                            # Let's assume safely: if we can't tell, count as enabled to avoid false positive.
                             is_enabled = True
                        
                        if is_enabled:
                            has_active_owner = True
                            all_disabled = False
                            # Optimization: If we found one active owner, it's not orphaned.
                            # But we continue to list all owners? No, we can break if we just care about "Is this orphaned?"
                            # but for "all owners list" we might want to continue.
                    
                    if not has_active_owner:
                        is_orphaned = True
                        orphan_reason = "All Owners Disabled/Deleted"

                if is_orphaned:
                    orphaned_apps.append({
                        "App": app.display_name or "Unknown",
                        "AppId": app.app_id,
                        "Type": orphan_reason,
                        "OwnerCount": len(owners) if owners else 0,
                        "Owners": "; ".join(owner_names)
                    })

        # Report
        if not orphaned_apps:
            print("No orphaned applications found.")
        else:
            print(f"\nFound {len(orphaned_apps)} orphaned applications:\n")
            print(f"{'App Name':<30} | {'Type':<25} | {'App ID'}")
            print("-" * 80)
            for item in orphaned_apps:
                print(f"{item['App'][:28]:<30} | {item['Type']:<25} | {item['AppId']}")

        # Export
        if args.output:
            print(f"\nExporting list to {args.output}...")
            try:
                with open(args.output, mode='w', newline='', encoding='utf-8') as f:
                    writer = csv.DictWriter(f, fieldnames=["App", "AppId", "Type", "OwnerCount", "Owners"])
                    writer.writeheader()
                    writer.writerows(orphaned_apps)
                print("Export complete.")
            except Exception as e:
                print(f"Failed to export CSV: {e}")

    except Exception as e:
        print(f"An error occurred: {e}")
        if "403" in str(e):
             print("\n[!] PERMISSION ERROR: Inspecting owners may require 'User.Read.All' and 'Application.Read.All'.")

if __name__ == "__main__":
    asyncio.run(main())
