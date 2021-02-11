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
    [string] $ConfigurationFileName = "wvdoptimizationtool.parameters.json"
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
Set-Logger "C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension\executionLog\wvdOptimizationTool" # inside "executionCustomScriptExtension_$scriptName_$date.log"

LogInfo("###################")
LogInfo("## 0 - LOAD DATA ##")
LogInfo("###################")

$ConfigurationFilePath = Join-Path $PSScriptRoot $ConfigurationFileName
$ConfigurationJson = Get-Content -Path $ConfigurationFilePath -Raw -ErrorAction 'Stop'
try { $wvdoptimizationtoolconfig = $ConfigurationJson | ConvertFrom-Json -ErrorAction 'Stop' }
catch {
    Write-Error "Configuration JSON content could not be converted to a PowerShell object" -ErrorAction 'Stop'
}

LogInfo("##################")
LogInfo("## 1 - EVALUATE ##")
LogInfo("##################")

# Get SIG img id in form '/subscriptions/<subscriptionId>/resourceGroups/<image-resource-group-name>/providers/Microsoft.Compute/galleries/<SIG name>/images/<image name>/versions/<version>'
$imgRefId = $wvdoptimizationtoolconfig.wvdoptimizationtoolconfig.customImageRefId
LogInfo("Found imgRefId variable set to $imgRefId")

# Get the image definition name from the image Id
$imgDefName = $imgRefId.split("/")[10]
# Get the Windows Build Version from the Definition Name
$win10Build = $imgDefName.split("-")[1]

# Build 20h2 is known as 2009
If ($win10Build -eq "20h2") {
    $win10Build = "2009"
}
LogInfo("Found win10build configuration variable set to $win10Build")

LogInfo("####################################")
LogInfo("# 2. Extract WVD Optimization Tool #")
LogInfo("####################################")

$WVDOptimizationToolArchivePath = Join-Path $PSScriptRoot "azure-wvd-optimization-tool-master.zip"

LogInfo("Expanding Archive $WVDOptimizationToolArchivePath into $PSScriptRoot")
Expand-Archive -Path $WVDOptimizationToolArchivePath -DestinationPath $PSScriptRoot
LogInfo("Archive expanded")

LogInfo("###############################")
LogInfo("## 3 - Run WVD Optimizations ##")
LogInfo("###############################")

$split = $wvdoptimizationtoolconfig.wvdoptimizationtoolconfig.domainName.Split(".")
$username = $($split[0] + "\" + $wvdoptimizationtoolconfig.wvdoptimizationtoolconfig.domainJoinUsername)

LogInfo("Using PSExec, set execution policy for the admin user")
$scriptBlock = { .\psexec /accepteula -h -u $username -p $domainJoinPassword -c -f "powershell.exe" Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope CurrentUser -Force }
Invoke-Command $scriptBlock -Verbose

LogInfo("Execution policy for the admin user set. Setting path to $PSScriptRoot\azure-wvd-optimization-tool-master and running WVD Optimization Tool for Windows 10 build $win10Build.")
$scriptBlock = { .\psexec /accepteula -h -u $username -p $domainJoinPassword -c -f "powershell.exe" ""Set-Location $test\azure-wvd-optimization-tool-master"; ".\Win10_VirtualDesktop_Optimize.ps1 -WindowsVersion 2009 -Verbose"" }
Invoke-Command $scriptBlock -Verbose

LogInfo("WVD Optimizations Completed")

