import logging
import azure.functions as func
import os
import csv
import io
from datetime import datetime, timezone, timedelta
from azure.identity import DefaultAzureCredential
from msgraph import GraphServiceClient
from msgraph.generated.applications.applications_request_builder import ApplicationsRequestBuilder
from azure.mgmt.resourcegraph import ResourceGraphClient
from azure.mgmt.resourcegraph.models import QueryRequest

app = func.FunctionApp()

# Helper to get Graph Client
def get_graph_client():
    credential = DefaultAzureCredential()
    return GraphServiceClient(credentials=credential, scopes=['https://graph.microsoft.com/.default'])

# Helper to log results
def log_results(title, results):
    if not results:
        logging.info(f"[{title}] No items found.")
        return

    logging.info(f"[{title}] Found {len(results)} items:")
    for item in results:
        logging.info(item)

@app.schedule(schedule="0 0 8 * * *", arg_name="myTimer", run_on_startup=False,
              use_monitor=False) 
def timer_audit_secrets(myTimer: func.TimerRequest) -> None:
    if myTimer.past_due:
        logging.info('The timer is past due!')

    logging.info('Starting audit for secrets expiring soon...')
    
    # Logic from entra_app_secret_audit.py
    days = 30 # Default
    threshold_date = datetime.now(timezone.utc) + timedelta(days=days)
    
    async def run_audit():
        graph_client = get_graph_client()
        query_params = {
            "$select": ["id", "appId", "displayName", "passwordCredentials", "keyCredentials"]
        }
        
        # Note: Pagination should be handled properly in production.
        result = await graph_client.applications.get(request_configuration={'query_parameters': query_params})
        
        apps_with_expiring_creds = []
        if result and result.value:
            for app in result.value:
                app_name = app.display_name or "Unknown"
                
                # Check Secrets
                if app.password_credentials:
                    for secret in app.password_credentials:
                        if secret.end_date_time and secret.end_date_time <= threshold_date:
                            apps_with_expiring_creds.append({
                                "App": app_name,
                                "Type": "Secret",
                                "Expires": str(secret.end_date_time)
                            })

                # Check Certificates
                if app.key_credentials:
                    for key in app.key_credentials:
                        if key.end_date_time and key.end_date_time <= threshold_date:
                            apps_with_expiring_creds.append({
                                "App": app_name,
                                "Type": "Certificate",
                                "Expires": str(key.end_date_time)
                            })
                            
        log_results("Secrets Expiring", apps_with_expiring_creds)

    import asyncio
    asyncio.run(run_audit())

@app.schedule(schedule="0 0 8 * * *", arg_name="myTimer", run_on_startup=False,
              use_monitor=False) 
def timer_audit_unused_apps(myTimer: func.TimerRequest) -> None:
    logging.info('Starting audit for unused apps...')
    
    days = 365
    threshold_date = datetime.now(timezone.utc) - timedelta(days=days)

    async def run_audit():
        graph_client = get_graph_client()
        query_params = {
            "$select": ["appId", "displayName", "signInActivity", "id"]
        }
        
        try:
            result = await graph_client.service_principals.get(request_configuration={'query_parameters': query_params})
            unused_apps = []
            if result and result.value:
                for sp in result.value:
                    last_sign_in = None
                    if sp.sign_in_activity and sp.sign_in_activity.last_sign_in_date_time:
                        last_sign_in = sp.sign_in_activity.last_sign_in_date_time
                    
                    if last_sign_in is None or last_sign_in <= threshold_date:
                        unused_apps.append({
                            "App": sp.display_name or "Unknown",
                            "LastSignIn": str(last_sign_in) if last_sign_in else "Never"
                        })
            
            log_results("Unused Apps", unused_apps)
        except Exception as e:
            logging.error(f"Error checking unused apps: {e}")

    import asyncio
    asyncio.run(run_audit())

@app.schedule(schedule="0 0 8 * * *", arg_name="myTimer", run_on_startup=False,
              use_monitor=False) 
def timer_audit_orphaned_apps(myTimer: func.TimerRequest) -> None:
    logging.info('Starting audit for orphaned apps...')

    async def run_audit():
        graph_client = get_graph_client()
        
        request_config = ApplicationsRequestBuilder.ApplicationsRequestBuilderGetRequestConfiguration(
            query_parameters = ApplicationsRequestBuilder.ApplicationsRequestBuilderGetQueryParameters(
                select = ["id", "appId", "displayName"],
                expand = ["owners"]
            )
        )
        
        try:
            result = await graph_client.applications.get(request_configuration=request_config)
            orphaned_apps = []
            if result and result.value:
                for app in result.value:
                    owners = app.owners
                    is_orphaned = False
                    reason = ""
                    
                    if not owners:
                        is_orphaned = True
                        reason = "No Owners"
                    else:
                        # Check disabled owners
                        all_disabled = True
                        for owner in owners:
                             # Default true if property missing/unreadable to avoid false positives
                            is_enabled = True 
                            if hasattr(owner, 'account_enabled'):
                                if owner.account_enabled is True:
                                    is_enabled = True
                                else:
                                    is_enabled = False
                            
                            if is_enabled:
                                all_disabled = False
                                break
                        
                        if all_disabled:
                            is_orphaned = True
                            reason = "All Owners Disabled"
                    
                    if is_orphaned:
                        orphaned_apps.append({
                            "App": app.display_name or "Unknown",
                            "Reason": reason
                        })
            
            log_results("Orphaned Apps", orphaned_apps)
        except Exception as e:
            logging.error(f"Error checking orphaned apps: {e}")

    import asyncio
    asyncio.run(run_audit())

@app.schedule(schedule="0 0 8 * * *", arg_name="myTimer", run_on_startup=False,
              use_monitor=False) 
def timer_defender_report(myTimer: func.TimerRequest) -> None:
    logging.info('Starting Defender for Cloud new items report...')
    
    try:
        credential = DefaultAzureCredential()
        arg_client = ResourceGraphClient(credential)
        days = 7
        
        query_recommendations = f"""
        securityresources
        | where type == "microsoft.security/assessments"
        | where properties.status.code == "Unhealthy"
        | where properties.status.statusChangeDate > ago({days}d)
        | project Name=properties.displayName, Severity=properties.metadata.severity, Status=properties.status.code
        """
        
        query_attack_paths = f"""
        securityresources
        | where type == "microsoft.security/attackpaths"
        | project Name=properties.displayName, Severity=properties.riskLevel, Status=properties.status
        | where properties.creationTime > ago({days}d) or isnull(properties.creationTime)
        """
        
        request_reco = QueryRequest(query=query_recommendations)
        response_reco = arg_client.resources(request_reco)
        
        recos = []
        if response_reco.data:
            recos = response_reco.data
        
        log_results("New Defender Recommendations", recos)
        
        # Try Attack Paths
        try:
            request_paths = QueryRequest(query=query_attack_paths)
            response_paths = arg_client.resources(request_paths)
            paths = []
            if response_paths.data:
                paths = response_paths.data
            log_results("New Attack Paths", paths)
        except Exception as e:
             logging.warning(f"Failed to query attack paths: {e}")

    except Exception as e:
        logging.error(f"Error checking Defender items: {e}")
