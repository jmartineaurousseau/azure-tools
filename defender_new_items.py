import asyncio
import argparse
import json
import csv
import os
from datetime import datetime, timezone, timedelta
from azure.identity import DefaultAzureCredential
from azure.mgmt.resourcegraph import ResourceGraphClient
from azure.mgmt.resourcegraph.models import QueryRequest

async def main():
    parser = argparse.ArgumentParser(description="Report new Defender for Cloud recommendations and Attack Paths.")
    parser.add_argument("--days", type=int, default=7, help="Look back period in days (default: 7)")
    parser.add_argument("--output", help="Path to export results as CSV (e.g., defender_report.csv)")
    args = parser.parse_args()

    print(f"Starting Defender for Cloud audit for items new in the last {args.days} days...")

    # Load config (optional tenant/subscription context)
    tenant_id = None
    config_path = "audit_config.json"
    if os.path.exists(config_path):
        try:
            with open(config_path, "r") as f:
                config = json.load(f)
                tenant_id = config.get("tenant_id")
                if tenant_id and "ENTER_YOUR" in tenant_id:
                    tenant_id = None
        except Exception:
            pass

    print("Using default credential from environment/CLI context.")
    credential = DefaultAzureCredential()

    try:
        # Initialize Resource Graph Client
        # Note: ResourceGraphClient is synchronous in current azure-mgmt-resourcegraph versions usually, 
        # but we can wrap it or use it directly.
        arg_client = ResourceGraphClient(credential)

        # Calculate time threshold
        # KQL uses ago(), but we can insert the specific date string or just use ago(Xd)
        # Using string interpolation for safety and control.
        days = args.days
        
        # Query 1: Recommendations (Assessments) that changed status recently
        # We look for assessments that are currently 'Unhealthy' and whose status changed recently?
        # Or just any status change? Usually we care about new 'Unhealthy'.
        
        query_recommendations = f"""
        securityresources
        | where type == "microsoft.security/assessments"
        | where properties.status.code == "Unhealthy"
        | where properties.status.statusChangeDate > ago({days}d)
        | project 
            Type="Recommendation", 
            Name=properties.displayName, 
            Severity=properties.metadata.severity, 
            Status=properties.status.code, 
            ChangeDate=properties.status.statusChangeDate, 
            Resource=id
        | order by ChangeDate desc
        """
        
        # Query 2: Attack Paths (Preview/New Feature data structure)
        # Attack paths might not have a clean 'creationDate' in all API versions exposed via ARG yet.
        # But let's try to find them or Alerts as a proxy for "Threats".
        # Let's query 'microsoft.security/attackpaths' if available.
        # If no timestamp, we just list them as "Active Attack Path".
        
        query_attack_paths = f"""
        securityresources
        | where type == "microsoft.security/attackpaths"
        | project 
            Type="AttackPath", 
            Name=properties.displayName, 
            Severity=properties.riskLevel, 
            Status=properties.status, 
            ChangeDate=properties.creationTime, 
            Resource=id
        | where ChangeDate > ago({days}d) or isnull(ChangeDate)
        | order by ChangeDate desc
        """
        # Note: AttackPath properties schema can vary. 'riskLevel' and 'creationTime' are best guesses based on common schema.
        # If creationTime is null, it might be old, but let's include for visibility if desired. 
        # Actually logic says "new ... like last week", so maybe filter strict?
        # Let's try strict filter first.
        
        print("Querying Azure Resource Graph for Recommendations...")
        
        # combine queries or run separate? Separate is safer for schema differences.
        
        results = []
        
        # Run Reco Query
        request_reco = QueryRequest(query=query_recommendations)
        response_reco = arg_client.resources(request_reco)
        
        if response_reco.data:
            results.extend(response_reco.data)
            print(f"Found {len(response_reco.data)} new/changed recommendations.")

        print("Querying Azure Resource Graph for Attack Paths...")
        try:
            request_paths = QueryRequest(query=query_attack_paths)
            response_paths = arg_client.resources(request_paths)
            if response_paths.data:
                results.extend(response_paths.data)
                print(f"Found {len(response_paths.data)} new attack paths.")
        except Exception as e:
            print(f"Warning: Failed to query Attack Paths (might not be enabled or supported in this tenant): {e}")

        # Report
        if not results:
            print(f"No new Defender items found in the last {args.days} days.")
        else:
            print(f"\nFound {len(results)} items:\n")
            print(f"{'Type':<20} | {'Severity':<10} | {'Change Date':<25} | {'Name'}")
            print("-" * 100)
            for item in results:
                # Handle potentially missing keys safely
                itype = item.get('Type', 'Unknown')
                isev = item.get('Severity', 'Unknown')
                idate = item.get('ChangeDate', 'N/A')
                iname = item.get('Name', 'Unknown')
                
                print(f"{itype:<20} | {isev:<10} | {str(idate):<25} | {iname}")

        # Export
        if args.output:
            print(f"\nExporting to {args.output}...")
            try:
                with open(args.output, mode='w', newline='', encoding='utf-8') as f:
                    # Determine all potential keys from results for header
                    if results:
                        keys = list(results[0].keys())
                        writer = csv.DictWriter(f, fieldnames=keys)
                        writer.writeheader()
                        writer.writerows(results)
                print("Export complete.")
            except Exception as e:
                print(f"Failed to export CSV: {e}")

    except Exception as e:
        print(f"An error occurred: {e}")
        if "AuthorizationFailed" in str(e):
            print("\n[!] PERMISSION ERROR: Reading Security data requires 'Security Reader' permissions.")

if __name__ == "__main__":
    asyncio.run(main())
