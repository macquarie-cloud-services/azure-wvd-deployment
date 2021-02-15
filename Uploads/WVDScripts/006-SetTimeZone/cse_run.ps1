[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $false)]
    [Hashtable] $DynParameters,

    [Parameter(Mandatory = $false)]
    [string] $AzureAdminUpn,

    [Parameter(Mandatory = $false)]
    [string] $AzureAdminPassword,

    [Parameter(Mandatory = $false)]
    [string] $domainJoinPassword,
    
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string] $ipinfoAPI = "2a953b13293a36",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string] $azureMapsAPI = "wMoWsC1v2C9CUSmHgZSmHOTLoJGBG1h6todG1P8NdGQ"
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

Set-Logger "C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension\executionLog\SetTimeZone" # inside "executionCustomScriptExtension_$scriptName_$date.log"

LogInfo("Getting VM location data via API call to ipinfo.io")
$locData = Invoke-RestMethod "https://ipinfo.io?token=$ipinfoAPI" -ContentType 'Application/Json'

LogInfo("Convert IANA timezone to Windows timezone using Azure Map API")
$restParams = @{
    Method = 'Get'
    Uri = "https://atlas.microsoft.com/timezone/enumWindows/json?subscription-key=$azureMapsAPI&api-version=1.0"
    ContentType = 'Application/Json'
}
$tzList = Invoke-RestMethod @restParams
$tzresult = $tzList | Where-Object { $locData.timezone -in $_.IanaIds } | Get-Unique

$scriptBlock = { Set-TimeZone -Id $tzresult.WindowsId }
LogInfo("Invoking command with the following scriptblock: $scriptBlock")
Invoke-Command $scriptBlock -Verbose

LogInfo("Timezone successfully set")

$scriptBlock = { Restart-Computer -Force }
LogInfo("Restarting VM to apply customisations.")
Invoke-Command $scriptBlock -Verbose
