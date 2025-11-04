# Better Container App Logging Options

# Option 1: Use Log Analytics (best for production)
# Get the Log Analytics workspace ID
$logAnalyticsId = az containerapp env show -n dev-rap-cae -g rg-raptor-test --query "properties.appLogsConfiguration.logAnalyticsConfiguration.customerId" -o tsv

# Query logs using Kusto (KQL)
az monitor log-analytics query -w $logAnalyticsId --analytics-query "ContainerAppConsoleLogs_CL | where ContainerAppName_s == 'dev-rap-be' | order by TimeGenerated desc | take 100" -o table

# Option 2: Stream logs via Azure CLI (more reliable than --follow)
az containerapp logs show -n dev-rap-be -g rg-raptor-test --tail 50

# Option 3: Use Azure Portal
# Navigate to: Container App  Monitoring  Log stream (live streaming)

# Option 4: Connect to container console (if enabled)
az containerapp exec -n dev-rap-be -g rg-raptor-test --command /bin/sh

