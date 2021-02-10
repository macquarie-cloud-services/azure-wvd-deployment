[CmdletBinding(SupportsShouldProcess = $true)]
param (
    # [Parameter(Mandatory = $true)]
    # [ValidateNotNullOrEmpty()]
    # [string] $storageAccountKey,

    [Parameter(Mandatory = $false)]
    [Hashtable] $DynParameters,

    [Parameter(Mandatory = $false)]
    [string] $AzureAdminUpn,

    [Parameter(Mandatory = $true)]
    [string] $AzureAdminPassword,

    [Parameter(Mandatory = $true)]
    [string] $domainJoinPassword,
    
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string] $ConfigurationFileName = "azfiles.parameters.json"
)

#####################################

##########
# Helper #
##########
#region Functions
function LogInfo($message) {
    Log "Info" $message
}

function LogError($message) {
    Log "Error" $message
}

function LogSkip($message) {
    Log "Skip" $message
}

function LogWarning($message) {
    Log "Warning" $message
}

function Log {

    <#
    .SYNOPSIS
   Creates a log file and stores logs based on categories with tab seperation
    .PARAMETER category
    Category to put into the trace
    .PARAMETER message
    Message to be loged
    .EXAMPLE
    Log 'Info' 'Message'
    #>

    Param (
        $category = 'Info',
        [Parameter(Mandatory = $true)]
        $message
    )

    $date = get-date
    $content = "[$date]`t$category`t`t$message`n"
    Write-Verbose "$content" -verbose

    if (! $script:Log) {
        $File = Join-Path $env:TEMP "log.log"
        Write-Error "Log file not found, create new $File"
        $script:Log = $File
    }
    else {
        $File = $script:Log
    }
    Add-Content $File $content -ErrorAction Stop
}

function Set-Logger {
    <#
    .SYNOPSIS
    Sets default log file and stores in a script accessible variable $script:Log
    Log File name "executionCustomScriptExtension_$date.log"
    .PARAMETER Path
    Path to the log file
    .EXAMPLE
    Set-Logger
    Create a logger in
    #>

    Param (
        [Parameter(Mandatory = $true)]
        $Path
    )

    # Create central log file with given date

    $date = Get-Date -UFormat "%Y-%m-%d %H-%M-%S"

    $scriptName = (Get-Item $PSCommandPath ).Basename
    $scriptName = $scriptName -replace "-", ""

    Set-Variable logFile -Scope Script
    $script:logFile = "executionCustomScriptExtension_" + $scriptName + "_" + $date + ".log"

    if ((Test-Path $path ) -eq $false) {
        $null = New-Item -Path $path -type directory
    }

    $script:Log = Join-Path $path $logfile

    Add-Content $script:Log "Date`t`t`tCategory`t`tDetails"
}
#endregion


## MAIN
#Set-Logger "C:\WindowsAzure\CustomScriptExtension\Log" # inside "executionCustomScriptExtension_$date.log"
Set-Logger "C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension\executionLog\wvdoptimizationtool" # inside "executionCustomScriptExtension_$scriptName_$date.log"

LogInfo("####################################")
LogInfo("# 1. Extract WVD Optimization Tool #")
LogInfo("####################################")

$WVDOptimizationToolArchivePath = Join-Path $PSScriptRoot "azure-wvd-optimization-tool-master.zip"

LogInfo("Expanding Archive $WVDOptimizationToolArchivePath into $PSScriptRoot")
Expand-Archive -Path $WVDOptimizationToolArchivePath -DestinationPath $PSScriptRoot
LogInfo("Archive expanded")

LogInfo("###############################")
LogInfo("## 2 - Run WVD Optimizations ##")
LogInfo("###############################")

LogInfo("Using PSExec, set execution policy for the admin user")
$scriptBlock = { .\psexec /accepteula -h -u $username -p $domainJoinPassword -c -f "powershell.exe" Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope CurrentUser -Force }
Invoke-Command $scriptBlock -Verbose

LogInfo("Execution policy for the admin user set. Run WVD optimization tool")
& "$PSScriptRoot\azure-wvd-optimization-tool-master\azure-wvd-optimization-tool-master\Win10_VirtualDesktop_Optimize.ps1 -WindowsVersion 2009 -Verbose"
LogInfo("WVD Optimizations Completed")
