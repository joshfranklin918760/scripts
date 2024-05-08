# -----------------------------------------------------------------------------
# Script Configuration
# -----------------------------------------------------------------------------
# Name: Domain controller health check
# Description: This script runs a series of helath checks on an Active 
# Directory Domain Controller and reports on any errors.

# -----------------------------------------------------------------------------
# Monitor Configuration
# -----------------------------------------------------------------------------
# Script: Domain controller health check
# Script output: Contains
# Output value: ALERT
# Run frequency: Minutes
# Duration: 180
# -----------------------------------------------------------------------------

# Check if the device is a domain controller
$domainController = (Get-WmiObject -Query "SELECT * FROM Win32_ComputerSystem").DomainRole -in 4, 5
if (-not $domainController) {
    write-host "This device is not a domain controller, exiting."
    exit 1
}


# This function tests the name against DNS.
Function Get-DomainControllerNSLookup($DomainNameInput) {
    Write-Verbose "..running function Get-DomainControllerNSLookup" 
    try {
        $domainControllerNSLookupResult = Resolve-DnsName $DomainNameInput -Type A | select -ExpandProperty IPAddress

        $domainControllerNSLookupResult = 'Passed'
    }
    catch {
        $domainControllerNSLookupResult = 'Fail'
    }
    return $domainControllerNSLookupResult
}

# This function tests the domain controller uptime.
Function Get-DomainControllerUpTime($DomainNameInput) {
    Write-Verbose "..running function Get-DomainControllerUpTime" 

    If ((Test-Connection $DomainNameInput -Count 1 -quiet) -eq $True) {
        try {
            $W32OS = Get-WmiObject -Class Win32_OperatingSystem -ComputerName $DomainNameInput -ErrorAction SilentlyContinue
            $timespan = $W32OS.ConvertToDateTime($W32OS.LocalDateTime) - $W32OS.ConvertToDateTime($W32OS.LastBootUpTime)
            [int]$uptime = "{0:00}" -f $timespan.TotalHours
        }
        catch [exception] {
            $uptime = 'WMI Failure'
        }
    }

    Else {
        $uptime = '0'
    }
    return $uptime  
}

# This function checks the DIT file drive space.
Function Get-DITFileDriveSpace($DomainNameInput) {
    Write-Verbose "..running function Get-DITFileDriveSpace" 

    If ((Test-Connection $DomainNameInput -Count 1 -quiet) -eq $True) {
        try {
            $key = "SYSTEM\CurrentControlSet\Services\NTDS\Parameters"
            $valuename = "DSA Database file"
            $reg = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine', $DomainNameInput)
            $regkey = $reg.opensubkey($key)
            $NTDSPath = $regkey.getvalue($valuename)
            $NTDSPathDrive = $NTDSPath.ToString().Substring(0, 2)
            $NTDSPathFilter = '"' + 'DeviceID=' + "'" + $NTDSPathDrive + "'" + '"'
            $NTDSDiskDrive = Get-WmiObject -Class Win32_LogicalDisk -ComputerName $DomainNameInput -ErrorAction SilentlyContinue | ? { $_.DeviceID -eq $NTDSPathDrive }
            $NTDSPercentFree = [math]::Round($NTDSDiskDrive.FreeSpace / $NTDSDiskDrive.Size * 100)
        }
        catch [exception] {
            $NTDSPercentFree = 'WMI Failure'
        }
    }

    Else {
        $NTDSPercentFree = '0'
    }
    return $NTDSPercentFree 
}

# This function checks the DNS, NTDS and Netlogon services.
Function Get-DomainControllerServices($DomainNameInput) {
    Write-Verbose "..running function DomainControllerServices"
    $thisDomainControllerServicesTestResult = New-Object PSObject
    $thisDomainControllerServicesTestResult | Add-Member NoteProperty -name DNSService -Value $null
    $thisDomainControllerServicesTestResult | Add-Member NoteProperty -name NTDSService -Value $null
    $thisDomainControllerServicesTestResult | Add-Member NoteProperty -name NETLOGONService -Value $null

    If ((Test-Connection $DomainNameInput -Count 1 -quiet) -eq $True) {
        If ((Get-Service -ComputerName $DomainNameInput -Name DNS -ErrorAction SilentlyContinue).Status -eq 'Running') {
            $thisDomainControllerServicesTestResult.DNSService = 'Passed'
        }
        Else {
            $thisDomainControllerServicesTestResult.DNSService = 'Fail'
        }
        If ((Get-Service -ComputerName $DomainNameInput -Name NTDS -ErrorAction SilentlyContinue).Status -eq 'Running') {
            $thisDomainControllerServicesTestResult.NTDSService = 'Passed'
        }
        Else {
            $thisDomainControllerServicesTestResult.NTDSService = 'Fail'
        }
        If ((Get-Service -ComputerName $DomainNameInput -Name netlogon -ErrorAction SilentlyContinue).Status -eq 'Running') {
            $thisDomainControllerServicesTestResult.NETLOGONService = 'Passed'
        }
        Else {
            $thisDomainControllerServicesTestResult.NETLOGONService = 'Fail'
        }
    }

    Else {
        $thisDomainControllerServicesTestResult.DNSService = 'Fail'
        $thisDomainControllerServicesTestResult.NTDSService = 'Fail'
        $thisDomainControllerServicesTestResult.NETLOGONService = 'Fail'
    }
    return $thisDomainControllerServicesTestResult
} 

# This function runs five DCDiag tests and saves them in a variable for later processing.
Function Get-DomainControllerDCDiagTestResults($DomainNameInput) {
    Write-Verbose "..running function Get-DomainControllerDCDiagTestResults"

    $DCDiagTestResults = New-Object Object
    If ((Test-Connection $DomainNameInput -Count 1 -quiet) -eq $True) {

        $DCDiagTest = (Dcdiag.exe /s:$DomainNameInput /test:services /test:FSMOCheck /test:KnowsOfRoleHolders /test:Advertising /test:Replications) -split ('[\r\n]')

        $DCDiagTestResults | Add-Member -Type NoteProperty -Name "ServerName" -Value $DomainNameInput
        $DCDiagTest | % {
            Switch -RegEx ($_) {
                "Starting" { $TestName = ($_ -Replace ".*Starting test: ").Trim() }
                "passed test|failed test" {
                    If ($_ -Match "passed test") {
                        $TestStatus = "Passed"
                    }
                    Else {
                        $TestStatus = "Failed"
                    }
                }
            } 
            If ($TestName -ne $Null -And $TestStatus -ne $Null) {
                $DCDiagTestResults | Add-Member -Name $("$TestName".Trim()) -Value $TestStatus -Type NoteProperty -force
                $TestName = $Null; $TestStatus = $Null
            }
        }
        return $DCDiagTestResults
    }

    Else {
        $DCDiagTestResults | Add-Member -Type NoteProperty -Name "ServerName" -Value $DomainNameInput
        $DCDiagTestResults | Add-Member -Name Replications -Value 'Failed' -Type NoteProperty -force 
        $DCDiagTestResults | Add-Member -Name Advertising -Value 'Failed' -Type NoteProperty -force 
        $DCDiagTestResults | Add-Member -Name KnowsOfRoleHolders -Value 'Failed' -Type NoteProperty -force
        $DCDiagTestResults | Add-Member -Name FSMOCheck -Value 'Failed' -Type NoteProperty -force
        $DCDiagTestResults | Add-Member -Name Services -Value 'Failed' -Type NoteProperty -force 
    }
    return $DCDiagTestResults
}

# This function checks the server OS version.
Function Get-DomainControllerOSVersion ($DomainNameInput) {
    Write-Verbose "..running function Get-DomainControllerOSVersion"
    $W32OSVersion = (Get-WmiObject -Class Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
    return $W32OSVersion
}

# This function checks the free space on the OS drive
Function Get-DomainControllerOSDriveFreeSpace ($DomainNameInput) {
    Write-Verbose "..running function Get-DomainControllerOSDriveFreeSpace"

    If ((Test-Connection $DomainNameInput -Count 1 -quiet) -eq $True) {
        try {
            $thisOSDriveLetter = (Get-WmiObject Win32_OperatingSystem -ComputerName $DomainNameInput -ErrorAction SilentlyContinue).SystemDrive
            $thisOSPathFilter = '"' + 'DeviceID=' + "'" + $thisOSDriveLetter + "'" + '"'
            $thisOSDiskDrive = Get-WmiObject -Class Win32_LogicalDisk -ComputerName $DomainNameInput -ErrorAction SilentlyContinue | ? { $_.DeviceID -eq $thisOSDriveLetter }
            $thisOSPercentFree = [math]::Round($thisOSDiskDrive.FreeSpace / $thisOSDiskDrive.Size * 100)
        }

        catch [exception] {
            $thisOSPercentFree = 'WMI Failure'
        }
    }
    return $thisOSPercentFree
}

# This function checks for the DC replication error count 
function Get-ReplicationErrorCount {
    $ADReplicationFailure = Get-ADreplicationFailure -target localhost
    if ($ADReplicationFailure.FailureCount -gt 0) {
        $ADReplicationFailureCount = $ADReplicationFailure.FailureCount
    }
    else {
        $ADReplicationFailureCount = 0
    }

    if ($ADReplicationFailureCount -gt 0) {
        return "$ADReplicationFailureCount - Failure"
    }
    return "$ADReplicationFailureCount - Passed"
}

# This function checks for the last successful replication time
function Get-LastReplication {
    $LastReplication = Get-ADReplicationPartnerMetadata -target localhost

    # Initialize with a far future date
    $oldestSuccessTime = [DateTime]::MaxValue

    # If there are multiple connectors to more than one domain controller, then only evaluate the oldest value
    foreach ($partner in $LastReplication) {
        if ($partner.LastReplicationSuccess -lt $oldestSuccessTime) {
            $oldestSuccessTime = $partner.LastReplicationSuccess
        }
    }

    $timeDifference = (Get-Date).AddHours(-24)
    
    if ($oldestSuccessTime -lt $timeDifference) {    
        return "$oldestSuccessTime - Failure"
    }
    else {
        return "$oldestSuccessTime - Passed"
    }
}

#This function checks that there is more than one domain controller
function Get-DomainControllerCount {
    $DCList = dsquery server -forest
    $DCCount = $DCList.count
    if ($DCCount -gt 1) {
        return "$DCCount - Passed"
    }
    else {
        return "$DCCount - Failure"
    }
}

#This function checks that the forest and domain functional levels are below the server version
function Get-DomainFunctionalLevel {
    # Get the server version
    $serverVersion = (Get-WmiObject -Class Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
    $serverVersionNumber = $serverVersion -replace '\D+(\d+).+', '$1'

    # Get the domain version
    $domainVersion = (Get-ADDomain | Select -ExpandProperty DomainMode)
    $domainVersionNumber = $domainVersion -replace '\D+(\d+).+', '$1'

    # Check if the server version is higher than the domain version (except when the domain version is 2016)
    if ($domainVersion -ne "Windows2016Domain" -and [int]$serverVersionNumber -gt [int]$domainVersionNumber) {
        return "OS $serverVersionNumber > Domain $domainVersionNumber - Failure"
    }
    else {
        return "OS $serverVersionNumber & Domain $domainVersionNumber - Passed"
    } 
}

function Get-ForestFunctionalLevel {
    # Get the server version
    $serverVersion = (Get-WmiObject -Class Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
    $serverVersionNumber = $serverVersion -replace '\D+(\d+).+', '$1'

    # Get the forest version
    $forestVersion = (Get-ADForest | Select -ExpandProperty ForestMode)
    $forestVersionNumber = $forestVersion -replace '\D+(\d+).+', '$1'

    # Check if the server version is higher than the forest version (except when the forest version is 2016)
    if ($forestVersion -ne "Windows2016Forest" -and [int]$serverVersionNumber -gt [int]$forestVersionNumber) {
        return "OS $serverVersionNumber > Forest $forestVersionNumber - Failure"
    }
    else {
        return "OS $serverVersionNumber & Forest $forestVersionNumber - Passed"
    }
}


# Prepare for the DC tests
$allTestedDomainControllers = @()
$GetHostname = [System.Net.Dns]::GetHostByName($env:computerName) | Select-Object -ExpandProperty Hostname
$domainController = Get-ADDomainController -Server $GetHostname
$stopWatch = [System.Diagnostics.Stopwatch]::StartNew()

# Run all the tests
$DCDiagTestResults = Get-DomainControllerDCDiagTestResults $domainController.HostName

# Create a PS Custom object for the results
$thisDomainController = New-Object PSObject
$thisDomainController | Add-Member NoteProperty -name Server -Value $null
$thisDomainController | Add-Member NoteProperty -name Site -Value $null
$thisDomainController | Add-Member NoteProperty -name "OS Version" -Value $null
$thisDomainController | Add-Member NoteProperty -name "Operation Master Roles" -Value $null
$thisDomainController | Add-Member NoteProperty -name "DNS" -Value $null
$thisDomainController | Add-Member NoteProperty -name "Uptime (hrs)" -Value $null
$thisDomainController | Add-Member NoteProperty -name "DIT Free Space (%)" -Value $null
$thisDomainController | Add-Member NoteProperty -name "OS Free Space (%)" -Value $null
$thisDomainController | Add-Member NoteProperty -name "DNS Service" -Value $null
$thisDomainController | Add-Member NoteProperty -name "NTDS Service" -Value $null
$thisDomainController | Add-Member NoteProperty -name "NetLogon Service" -Value $null
$thisDomainController | Add-Member NoteProperty -name "DCDIAG: Advertising" -Value $null
$thisDomainController | Add-Member NoteProperty -name "DCDIAG: Replications" -Value $null
$thisDomainController | Add-Member NoteProperty -name "DCDIAG: FSMO KnowsOfRoleHolders" -Value $null
$thisDomainController | Add-Member NoteProperty -name "DCDIAG: FSMO Check" -Value $null
$thisDomainController | Add-Member NoteProperty -name "DCDIAG: Services" -Value $null
$thisDomainController | Add-Member NoteProperty -name "Replication Errors" -Value $null
$thisDomainController | Add-Member NoteProperty -name "Last Replication" -Value $null
$thisDomainController | Add-Member NoteProperty -name "DC Quantity" -Value $null
$thisDomainController | Add-Member NoteProperty -name "Domain Level" -Value $null
$thisDomainController | Add-Member NoteProperty -name "Forest Level" -Value $null
$thisDomainController | Add-Member NoteProperty -name "Processing Time" -Value $null

# Populate the properties with the test results
$thisDomainController.Server = ($domainController.HostName).ToLower()
$thisDomainController.Site = $domainController.Site
$thisDomainController."OS Version" = (Get-DomainControllerOSVersion $domainController.hostname)
$thisDomainController."Operation Master Roles" = if ($domainController.OperationMasterRoles) { $domainController.OperationMasterRoles -join ', ' } else { 'none' }
$thisDomainController.DNS = Get-DomainControllerNSLookup $domainController.HostName
$thisDomainController."Uptime (hrs)" = Get-DomainControllerUpTime $domainController.HostName
$thisDomainController."DIT Free Space (%)" = Get-DITFileDriveSpace $domainController.HostName
$thisDomainController."OS Free Space (%)" = Get-DomainControllerOSDriveFreeSpace $domainController.HostName
$thisDomainController."DNS Service" = (Get-DomainControllerServices $domainController.HostName).DNSService
$thisDomainController."NTDS Service" = (Get-DomainControllerServices $domainController.HostName).NTDSService
$thisDomainController."NetLogon Service" = (Get-DomainControllerServices $domainController.HostName).NETLOGONService
$thisDomainController."DCDIAG: Replications" = $DCDiagTestResults.Replications
$thisDomainController."DCDIAG: Advertising" = $DCDiagTestResults.Advertising
$thisDomainController."DCDIAG: FSMO KnowsOfRoleHolders" = $DCDiagTestResults.KnowsOfRoleHolders
$thisDomainController."DCDIAG: FSMO Check" = $DCDiagTestResults.FSMOCheck
$thisDomainController."DCDIAG: Services" = $DCDiagTestResults.Services
$thisDomainController."Replication Errors" = Get-ReplicationErrorCount
$thisDomainController."Last Replication" = Get-LastReplication
$thisDomainController."DC Quantity" = Get-DomainControllerCount
$thisDomainController."Domain Level" = Get-DomainFunctionalLevel
$thisDomainController."Forest Level" = Get-ForestFunctionalLevel
$thisDomainController."Processing Time" = $stopWatch.Elapsed.Seconds

# Function to format failures with an ALERT message
function Format-Failure($status) {
    if ($status -like '*Fail*') {

        return "Failed <-------------------- ALERT"
    }
    else {
        return $status
    }
}

# Function to format space alerts
function Format-SpaceAlert($space) {
    if ($space -lt 5) {
        return "$space% <-------------------- ALERT"
    }
    else {
        return "$space%"
    }
}

# Display the results with specific column widths
$output = @"
Server:                          $($thisDomainController.Server)
Site:                            $($thisDomainController.Site)
OS Version:                      $($thisDomainController.'OS Version')
Operation Master Roles:          $($thisDomainController.'Operation Master Roles')
DNS:                             $(Format-Failure $thisDomainController.DNS)
Uptime (hrs):                    $($thisDomainController.'Uptime (hrs)')
DIT Free Space (%):              $(Format-SpaceAlert $thisDomainController.'DIT Free Space (%)')
OS Free Space (%):               $(Format-SpaceAlert $thisDomainController.'OS Free Space (%)')
DNS Service:                     $(Format-Failure $thisDomainController.'DNS Service')
NTDS Service:                    $(Format-Failure $thisDomainController.'NTDS Service')
NetLogon Service:                $(Format-Failure $thisDomainController.'NetLogon Service')
DCDIAG: Advertising:             $(Format-Failure $thisDomainController.'DCDIAG: Advertising')
DCDIAG: Replications:            $(Format-Failure $thisDomainController.'DCDIAG: Replications')
DCDIAG: FSMO KnowsOfRoleHolders: $(Format-Failure $thisDomainController.'DCDIAG: FSMO KnowsOfRoleHolders')
DCDIAG: FSMO Check:              $(Format-Failure $thisDomainController.'DCDIAG: FSMO Check')
DCDIAG: Services:                $(Format-Failure $thisDomainController.'DCDIAG: Services')
Replication Errors:              $(Format-Failure $thisDomainController.'Replication Errors')
Last Replication:                $(Format-Failure $thisDomainController.'Last Replication')
DC Quantity:                     $(Format-Failure $thisDomainController.'DC Quantity')
Domain Level:                    $(Format-Failure $thisDomainController.'Domain Level')
Forest Level:                    $(Format-Failure $thisDomainController.'Forest Level')
Processing Time:                 $($thisDomainController.'Processing Time')

"@

# Output the custom formatted string
Write-Host $output

# Count the number of errors (including alerts)
$errorCount = ($output -split "`n" | Where-Object { $_ -like "*ALERT*" }).Count

#Display alert summary
if ($errorCount -gt 0) {
    Write-Host "Summary: $errorCount Error(s) Detected"
    exit 1
}
else {
    Write-Host "Summary: No Errors Detected"
}

# Generate output2 and insert into subject
# Output2: Display alert summary
if ($errorCount -gt 0) {
    $output2 = "Summary: $errorCount Error(s) Detected"
}
else {
    $output2 = "Summary: No Errors Detected"
}

# Email Results
# Define email parameters
$from = "josh@bynexcorp.com"
$to = "josh@bynexcorp.com"
$subject = $output2
$body = $output  # Assuming $output contains the formatted results
$smtpServer = "mail.smtp2go.com"
$smtpPort = 587  # Update with your SMTP port
$username = "bynex"
$password = ConvertTo-SecureString "Y3o3cHJyZGQ2aTgw" -AsPlainText -Force

# Create email credentials
$credential = New-Object System.Management.Automation.PSCredential ($username, $password)

# Send email
Send-MailMessage -From $from -To $to -Subject $subject -Body $body -SmtpServer $smtpServer -Port $smtpPort -Credential $credential -UseSsl
