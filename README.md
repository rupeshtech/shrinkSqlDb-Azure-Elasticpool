# shrinkSqlDb-Azure-Elasticpool
    This repository contains a powrshell script (runbook) to shrink Databases in Azure elastic pools.

## Flow
    Following is the flow of Scrip
1. This script take all Sql Servers (based on parameters passed)
2.  Then, loops over each sql server
3.  Then, retrives all elastic pools in each server.
4.  Then, loops over each get ealstic pool.
5.  Then, gets elasticpool metrics by exectuting sql command on master
6.  Then, looks of avg_allocated_storage_percent.
7.  If avg_allocated_storage_percent is very high (for ex: greater than 90 percent)
8.  Then, gets all Dbs into that elasticpool.
9.  Then, loops over foreach Databae.
10. Then retrives Database Storage Metrics
11. Then, looks for DatabaseDataSpaceAllocatedUnusedInMB (you can use percentage of Unused vs total space)
12. If DatabaseDataSpaceAllocatedUnusedInMB is quite hign (for ex greater than 1GB) 
13. Then, shirnks the Database

## Notes

    This script uses AZ modules of Microsoft Azure PowerShell

## Useful links

https://github.com/Azure/azure-powershell/blob/master/documentation/announcing-az-module.md
https://docs.microsoft.com/en-us/powershell/azure/new-azureps-module-az