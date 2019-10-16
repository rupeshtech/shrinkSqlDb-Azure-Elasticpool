<#
.SYNOPSIS
    This script shrinks DBs in Azure Elastic pools
.DESCRIPTION
    This script take all Sql Servers (based on parameters passed) and loops over each sql server. Then retrives all elastic pools in each server. Then loops over each get ealstic pool. 
    Gets elasticpool metrics by exectuting sql command on master and  looks of avg_allocated_storage_percent. If it is greater than 90 percent then gets all Dbs into that elasticpool
    and loops over foreach Databae. Then retrives Database Storage Metrics and looks for DatabaseDataSpaceAllocatedUnusedInMB and if is quite hign then Shirnks the Database
.EXAMPLE
    This script can be run directly in powershell or can be used as Runbook in Azure Automation Account
.INPUTS
    ResourceGroupName (Optional)
    ServerName (Optional)
.OUTPUTS
    Output are as below
    Afftected and Unaffcted Databases. By Afftected Database means Database where Shrinking is needed
    Affected and Unaffected Elasticpools. By Afftected Elasticpool means Elasticpools where used space is very high (more than 90%) 
.NOTES
    This script uses AZ modules of Microsoft Azure PowerShell.
    https://docs.microsoft.com/en-us/powershell/azure/new-azureps-module-az
    https://github.com/Azure/azure-powershell/blob/master/documentation/announcing-az-module.md
.ROLE
    This script uses Sql Scripts which needs credentials to run that script
.FUNCTIONALITY
    This script shrinks Databases automatically ans especially useful for very high number of sql servers, elasticpools and Databases (around 200,000 Dbs)
#>

param(
    [string]$ResourceGroupName,
    [string]$ServerName
)

#variables
$affectedDB = @()
$unAffectedDB = @()
$affectedPool = @()
$unAffectedPool = @()
$affectedPoolCount = 0
$unAffectedPoolCount = 0
$firewallFailedServer = @()
$dbshrinkresult = @()
$dbshrinkTruncateresult = @()

#Get Sql Login Credentials
$userName= Get-AutomationVariable -Name 'UserName'
$password=Get-AutomationVariable -Name 'Password'

# Use the Run As connection to login to Azure
function Login-AzureAutomation([bool] $AzModuleOnly) {
    try {
        $RunAsConnection = Get-AutomationConnection -Name "AzureRunAsConnection"
        Write-Output "Logging in to Azure ($AzureEnvironment)."

        if ($AzModuleOnly) {
            Add-AzAccount `
                -ServicePrincipal `
                -TenantId $RunAsConnection.TenantId `
                -ApplicationId $RunAsConnection.ApplicationId `
                -CertificateThumbprint $RunAsConnection.CertificateThumbprint `
                -Environment $AzureEnvironment

            Select-AzSubscription -SubscriptionId $RunAsConnection.SubscriptionID  | Write-Verbose
            Write-Output "Logged thru AZ module"
        } else {
            Add-AzureRmAccount `
                -ServicePrincipal `
                -TenantId $RunAsConnection.TenantId `
                -ApplicationId $RunAsConnection.ApplicationId `
                -CertificateThumbprint $RunAsConnection.CertificateThumbprint `
                -Environment $AzureEnvironment

            Select-AzureRmSubscription -SubscriptionId $RunAsConnection.SubscriptionID  | Write-Verbose
            Write-Output "Logged thru RM module"
        }
    } catch {
        if (!$RunAsConnection) {
            Write-Output $servicePrincipalConnection
            Write-Output $_.Exception
            $ErrorMessage = "Connection $connectionName not found."
            throw $ErrorMessage
        }

        throw $_.Exception
    }
}

#Login  using Az Module
$UseAzModule= $true
$AzureEnvironment ="AzureCloud"
Login-AzureAutomation $UseAzModule


$startTime = (Get-Date)

if($ServerName -eq $null -or $ServerName -eq '') {
    "Entered ServerName is: $ServerName"
    $servers = Get-AzSqlServer -ServerName $ServerName
}
elseif($ResourceGroupName -eq $null -or $ResourceGroupName -eq '') {
    "Entered ResourceGroupName is: $ResourceGroupName"
    $servers = Get-AzSqlServer -ResourceGroupName $ResourceGroupName
}
else{
    $servers = Get-AzSqlServer
}

$serverCount = $servers | Measure-Object
Write-Output "Server count is $($serverCount.Count)"

foreach ($server in $servers) {
    try  {
            Write-Output "Setting Firewall Rule for server : $($server.ServerName)"
            New-AzSqlServerFirewallRule -ResourceGroupName $server.ResourceGroupName -ServerName $server.ServerName -FirewallRuleName "FireWallRule1" -StartIpAddress "xxx.xxx.xx.xx" -EndIpAddress "xxx.xxx.xx.xx"
        }
        catch {
            Write-Error "Error occurred while setting firewall rule: $($_.Exception.Message)"
        }
    
    #Get Elastic pools in the server 
    $pools = Get-AzSqlElasticPool -ServerName $server.ServerName -ResourceGroupName $server.ResourceGroupName
    foreach ($pool in $pools){
        $elasticPoolStorageMetrics = @()
        $count =0

        $sqlCommandForElasticPool = "SELECT TOP 1 avg_allocated_storage_percent  FROM sys.elastic_pool_resource_stats WHERE elastic_pool_name = '$($pool.ElasticPoolName)' ORDER BY end_time DESC"
        $serverFqdn = "tcp:" + $server.ServerName + ".database.windows.net,1433"
        try {
            $elasticPoolStorageMetrics = (Invoke-Sqlcmd -ServerInstance $serverFqdn `
                -Database "master" `
                -Username $userName `
                -Password $password `
                -Query $sqlCommandForElasticPool)
        }
        catch {
            $firewallFailedServer = $firewallFailedServer + $server.ServerName
            Write-Output "Exception occured while getting Elasticpool metrics. ErrorMessage: $($_.Exception.Message)"
        }
        #Write-Output $elasticPoolStorageMetrics | ft
        Write-Output "Server name is: $($server.ServerName). Elasticpoolname is: $($pool.ElasticPoolName). avg_allocated_storage_percent is : $($elasticPoolStorageMetrics.avg_allocated_storage_percent)"

        # Check Allocated storage metics for elastic pool is above 90 percent. Change according to your use case
        if($elasticPoolStorageMetrics.avg_allocated_storage_percent -gt 90)
        {
            $affectedPoolCount = $affectedPoolCount +1
            $affectedPool = $affectedPool + "Servername : $($server.ServerName) poolname : $($pool.ElasticPoolName)"

            $databasesInPool = Get-AzSqlElasticPoolDatabase `
                -ResourceGroupName $server.ResourceGroupName `
                -ServerName $server.ServerName `
                -ElasticPoolName $pool.ElasticPoolName

            $databaseStorageMetrics = @()

            foreach ($database in $databasesInPool)
            {
                $count = $count +1 

                $sqlCommand = "SELECT DB_NAME() as DatabaseName, `
                                SUM(size/128.0) AS DatabaseDataSpaceAllocatedInMB, `
                                SUM(size/128.0 - CAST(FILEPROPERTY(name, 'SpaceUsed') AS int)/128.0) AS DatabaseDataSpaceAllocatedUnusedInMB `
                                FROM sys.database_files `
                                GROUP BY type_desc `
                                HAVING type_desc = 'ROWS'"

                try {
                    $databaseStorageMetrics = (Invoke-Sqlcmd -ServerInstance $serverFqdn `
                        -Database $database.DatabaseName `
                        -Username $userName `
                        -Password $password `
                        -Query $sqlCommand)
                }
                catch {
                    Write-Output "Exception occured while getting Database metrics. ErrorMessage: $($_.Exception.Message)"
                }

                Write-Output $databaseStorageMetrics | Sort-Object `
                    -Property DatabaseDataSpaceAllocatedUnusedInMB `
                    -Descending | Format-Table

                # Check Unused storage metics for Database is above 1GB. Change according to your use case
                if($databaseStorageMetrics.DatabaseDataSpaceAllocatedUnusedInMB -gt 1000) {
                    Write-Output "shinking started for pool : $($pool.ElasticPoolName) and DB:$($database.DatabaseName) and server: $($server.ServerName)"

                    $sqlTruncateCommandToFreeSpace = "DBCC SHRINKDATABASE (N'$($database.DatabaseName)', 0, TRUNCATEONLY)"
                    $sqlCommandToFreeSpace = "DBCC SHRINKDATABASE (N'$($database.DatabaseName)')"

                    $affectedDB =  $affectedDB + $database.DatabaseName
                    $dbshrinkTruncateresult = $dbshrinkTruncateresult + 
                                            (Invoke-Sqlcmd -ServerInstance $serverFqdn `
                                            -Database $database.DatabaseName `
                                            -Username $userName `
                                            -Password $password `
                                            -Query $sqlTruncateCommandToFreeSpace)

                    start-sleep -s 30

                    $dbshrinkresult = $dbshrinkresult + 
                                    (Invoke-Sqlcmd -ServerInstance $serverFqdn `
                                    -Database $database.DatabaseName `
                                    -Username $userName `
                                    -Password $password `
                                    -Query $sqlCommandToFreeSpace)

                    Write-Output "`n" "shinking succeedded for pool : $($pool.ElasticPoolName) and DB:$($database.DatabaseName)"
                }
                else {
                    Write-Output "shinking not started for pool : $($pool.ElasticPoolName) and DB:$($database.DatabaseName) . unused space is: $($databaseStorageMetrics.DatabaseDataSpaceAllocatedUnusedInMB) "
                    $unAffectedDB =  $unAffectedDB + $database.DatabaseName
                    if($count%50 -eq 0 ) {
                        Write-Output "shinking not started for pool : $($pool.ElasticPoolName) and DB:$($database.DatabaseName) and server: $($server.ServerName) . unused space is: $($databaseStorageMetrics.DatabaseDataSpaceAllocatedUnusedInMB) "
                    }
                }
            
            }
        }
        else{
            $unAffectedPoolCount = $unAffectedPoolCount +1
            $unAffectedPool = $unAffectedPool + $pool.ElasticPoolName
        }
    }
}


Write-Output "Afftected DB list"
Write-Output $affectedDB | Format-Table


Write-Output "UnAfftected DB list"
Write-Output $unAffectedDB | Format-Table

Write-Output "Afftected pool count is: $affectedPoolCount"
Write-Output $affectedPool | Format-Table


Write-Output "UnAfftected pool count is: $unAffectedPoolCount"
Write-Output $unAffectedPool | Format-Table

Write-Output "Db shrink result"
Write-Output $dbshrinkresult | Format-Table

Write-Output "Db shrink truncate result"
Write-Output $dbshrinkTruncateresult | Format-Table

$endTime = (Get-Date)
Write-Output "Total time taken is: $($endTime -$startTime)"