#assign values to variables here at the top, before the meaty parts

#Author: Brian Bowen
#Editor in Chief: Scott Ferrell
$version='Ver:26.7'
#modified to conform to TGS lot G only.



#run script with the word debug after it, for additional output
# ./thisscript.ps1 debug
#

########################################################################
###
###	Definitions Block
###
########################################################################

#$pathto_jar_file = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\DCGS Maintainer\VMmonitor"
#might also be 
$pathto_jar_file = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\DCGS Maintainer\VMmonitor.lnk' 
               
$ESXi1 = "10.6.70.101"
$ESXi2 = "10.6.70.102"
$ESXi3 = "10.6.70.103"

$ESXI1_CIMC = "10.6.70.11"
$ESXI2_CIMC = "10.6.70.12"
$ESXI3_CIMC = "10.6.70.13"


#this was moved off the router, into vRouter1, use for simple test of if vRouter1 is up or not
$SWITCHGW = "10.6.70.254"
#networking for the switch, could be located on a vNIA, and it might not be named vRouter1, adjust here
$vRouter1name = "vRouter1"

#comma separated list of vm, that we want to shut down last if possible
#not in use yet
#$vm_names_to_stop_last="tgs-vdi*,FS"

# TGS Lot G, cisco c220 m7 servers
$ESXiHosts_LotG = $ESXi1, $ESXi2, $ESXi3
$ESXiHosts = $ESXiHosts_LotG

#only list the vmnames for OTM in this, 1 per line, no commas or spaces
$OTM_listfile_path="C:\temp\OTM_VM_NAME_LIST.txt"


#only list the vmnames for FULL operation in this, 1 per line, no commas or spaces
#since full operation is OTM plus more vm, only list the additional vm names in this file.
$FULL_operation_listfile_path="C:\temp\FULLOP_VM_NAME_LIST.txt"

# NetApp
$NetAppIP='10.6.70.30'

# NetApp service processors
$NetAppSP_IP1='10.6.70.240'
$NetAppSP_IP2='10.6.70.241'

####  Are these in the lot G? They dont seem to have any actions in the functions below####
# UPS
$UPS1IP='10.6.70.60'
$UPS2IP='10.6.70.61'
$UPSPort='161'

# Manual VM Load Force Flag to override VMapp availability:
$ManualForce=$False

# For hopelessly no vCenter access
$ForceShutdown=$False

# HIERADATA
# Where to get VMware vCenter?
$vCenter="vcsa"
$vCenterIP = "10.6.70.4"


########################################################################
###
### HIERADATA
###     Puppet must add hieradata to:
###
###         gateway_fqdn
###
### Proper Puppet Line: ### $gateway_fqdn="tgs-portal.army.mil"
#$gateway_fqdn="int23.unclass.iesil"
$gateway_fqdn="g001.army.mil"

$dns_suffix="." + "$env:userdnsdomain"
$baseSys=$gateway_fqdn.Replace($dns_suffix,"")

if ($debug){write-host "baseSys is $baseSys"}
# Verify correct domain:
#Write-Host "gateway_fqdn=$gateway_fqdn dns_suffix=$dns_suffix baseSys=$baseSys"



### The pwdstore 
### These will be checked if preset to get values for login, if not present, the user will be asked for credentials, and then they will be checked, and if valid
### they will be encrypted and stored in the files below.
### HIERADATA? - vCenter PowerControl User
#vCenter user data
$userName = "administrator@vsphere.local"
$pfile="C:\temp\pwdStore.txt"
$ufile="C:\temp\userStore.txt"

# Admin user for ESXi Login
$userVName="root"
$pvfile="C:\temp\pwdVStore.txt"
$uvfile="C:\temp\userVStore.txt"

#Admin user for NetApp Login
$NetAppAdmin="admin"
$pnfile="C:\temp\pwdNStore.txt"
$unfile="C:\temp\userNStore.txt"

### delay timers ###

# Time for Delay in VC Startup Hold
$vcenter_startup_seconds=30

#not used anymore
#$vcSleepDelay=3
#$vcSleepCount=90

# Time for VM Shut down Delay 
#used when VM's are shut down via the host directly, and not via vCenter. its a fail safe
$vmSleepDelay=15

#time in seconds power cli will wait for a command response from a host or vCenter.
#recommend 20-30 seconds, default is 300 which if a host or something went wrong, can add up fast
#note: this may not work without setting it global as an admin.
$powercli_default_timeout=20


#end of editable values
########################################################################
#################   end of editable values    ##########################


########################################################################
# VMWare Authentication
#
########################################################################
###
###  Library Loads
###
########################################################################

Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Core
Add-Type -AssemblyName PresentationFramework

########################################################################
###
### Predefining Functions
###
########################################################################

#this has to be at column 1, do not indent (allows the use of netapp https)
Add-Type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    
    public class IDontCarePolicy : ICertificatePolicy {
        public IDontCarePolicy() {}
        public bool CheckValidationResult(
            ServicePoint sPoint, X509Certificate cert,
            WebRequest wRequest, int certProb) {
            return true;
        }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object IDontCarePolicy



#write-host $args[0]
#exit
if ($args[0] -imatch "debug")
{$debug = $true}
else {$debug = $false}
#
#exit
# Check for vCenter:

function isVCenterUp()
{
    $res=$false
    Write-Output "Checking vCenters state"
    if (Test-Connection $vCenterIP -Quiet)
    {
        Write-Output "vCenter is running"
        $res=$true
    }
    Write-Output "vCenter is not running"
    return $res
}

#create the file if not found, populate some base names.
#this only happens if its missing, it can be edited aftwards without being overwritten to allow for customization
function check_or_create_OTMlistfile()
{
    if (![System.IO.File]::Exists($OTM_listfile_path)) {
        Write-Host ""
        Write-Host "The OTM Operation VM name list file is missing so the script will create it"
	
        $stock_otm_vmlist="vRtrC8000
vRouter1
VCSA
DC1
Core
Gateway
GXPXplorer
Puppet
CORE
Web
MI
NetCfgSvr1
NLS
FMV
VSQL
ViewCon
ArcEnt
vNIA1"
        
        #create directory if its not there
        checkTargetDir $OTM_listfile_path
        $stock_otm_vmlist | Out-File -FilePath $OTM_listfile_path
        #provide a message, so they know, else it clears screen and content is lost
        #Write-Host ""
        #Write-Host ""
        #Read-Host -Prompt "Default OTM list created. Press any key to continue or CTRL+C to quit" | Out-Null
	Write-Host "If needed, edit the file then restart the script"
 	Write-Host "The file is located in $OTM_listfile_path "
	forceuserconsent
    }
}

function check_or_create_FULLOPlistfile()
{
    if (![System.IO.File]::Exists($FULL_operation_listfile_path)) {
        Write-Host ""
        Write-Host "        Missing file: $FULL_operation_listfile_path"
        Write-Host ""
        Write-Host "The Full Operation VM name list file is missing so the script will create it"
		
        $stock_full_vmlist="GPT
AGS1
AGS2
AGS3
GES
IOP1A
IOP1B
IOP1D
NESSUS
DC2
VIDEO
XPLORER
ZABBIX
DIBNODE
GDB
AESS
MAPPROXY
GPED-SVR-V1
AIMES1
LOGS
FS
VANTAGE
ArcVid
ArcIm
ArcGE
vNIA2
vNIA3
vNIA4
TGSMGMT
MTISD
AMP
ADB
NETMGMTSVR2
INFRA
SENSORINT
ArcNote
"

        #create directory if its not there
        checkTargetDir $FULL_operation_listfile_path
        $stock_full_vmlist | Out-File -FilePath $FULL_operation_listfile_path
        #provide a message, so they know, else it clears screen and content is lost
                #Write-Host ""
                #Write-Host ""
        #Read-Host -Prompt "Default FULL operation list created. Press any key to continue or CTRL+C to quit" | Out-Null
	Write-Host "If needed, edit the file then restart the script"
 	Write-Host "The file is located in $FULL_operation_listfile_path "
        Write-Host ""
        Write-warning "The Full Operation VM name list should not include VM names that are in the OTM Operation VM name list"
	forceuserconsent
    }
}

function forceuserconsent()
{
    $msg = 'Enter "Y" to continue or CTRL+C to exit'
    do {
        $response = Read-Host -Prompt $msg
    } until (($response -eq 'y') -or ($response -eq 'Y'))
}
#$vCenterAvailable=isVCenterUp
# Enable Execution:

# Load Modules or Plugins, depending on the system:
function loadModules()
{
  try
  {
    #
    # Ensure Plugins or Modules needed are loaded:
    #
    #region: Load VMware Snapin or Module (if not already loaded)
    #
    # Turn off CEIP prompt to not bother user
    ### Run issues? ### Set-PowerCLIConfiguration -Scope User -Confirm:$False -ParticipateInCEIP $False
    #
	Set-PowerCLIConfiguration -Scope User -Confirm:$False -ParticipateInCEIP $False
    if (!(Get-Module -Name VMware.VimAutomation.Core) -and (Get-Module -ListAvailable -Name VMware.VimAutomation.Core)) 
    {
        Write-Output "Loading the VMware Core Modules:"
        Import-Module -Name VMware.powercli -ErrorAction SilentlyContinue 4>$null
        Import-Module -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue
        $Loaded = $True
        Write-Output "Complete loading the VMware Core Modules"
    }
    elseif (!(Get-PSSnapin -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue) -and !(Get-Module -Name VMware.VimAutomation.Core) -and ($Loaded -ne $True))
    {
    Write-Error "Loading the VMware Core Snapin"
    if (!(Add-PSSnapin -PassThru VMware.VimAutomation.Core -ErrorAction SilentlyContinue) -and 
      !(Add-PSSnapin -PassThru VMware.VimAutomation.License -ErrorAction SilentlyContinue) -and 
      !(Add-PSSnapin -PassThru VMware.VimAutomation.DeployAutomation -ErrorAction SilentlyContinue) -and
      !(Add-PSSnapin -PassThru VMware.VimAutomation.ImageBuilder -ErrorAction SilentlyContinue) )
    {
      # Error out if loading fails
      Write-Error "`nError: Cannot load the VMware Snapin or Module. Is the PowerCLI installed?"
    }
    else
    {
      Write-Output "Completed loading the VMware Core Snapins"
    }
    }
    #endregion
  }
  catch
  {
    Write-Error "`nError: Cannot load the VMware Module. Is the PowerCLI installed?"
  }
}



########################################################################
###
###     Define VM List and Action:
###



# Verify Target Directory Available
function checkTargetDir($targetFile)
{
    if(!$targetFile)
    {return $false}
	# Check for Target Directory available:
	$tempdir=Split-Path -Path $targetFile
	If (!(test-path $tempdir))
	{
		New-Item -ItemType "directory" -force -Path $tempdir
        return $true
	}
}

# Get/Set Password Credentials from File
function getCredentials_vcenter($passFile, $userFile, $defUserName, $serverIP)
{


#this may not be the best place for it, but its really only vCenter that seems to be a problem
#basically, we need to find a way to wait out, the vCenter startup time
#this section will try http requests to wait out the poor timing that vcenter takes to start up.
#could probably be handled better. most people dont reset vcenter very often

#already defined up top
#$vcenterip='10.6.70.4'

$uri="https://$vCenterIP/ui/"
$wc = New-Object System.Net.WebClient
$vcenterready = $false
$attemptstoconnect=0
if ($debug){write-host "Testing vCenter fully started"}
do {
    
    try {
        $webdata = ""
        $webdata = $wc.DownloadString($uri)
        if ($webdata.Contains('<base href="/ui/">')) 
        {
        if ($debug){Write-Host "vCenter is now able to accept requests"}
        $vcenterready = $true
        }
    }
    catch {
        $statuscode = $_.Exception.Message
        if ($statuscode -like "*The remote server returned an error: (503) Server Unavailable.*")
        {
           Write-Host "vCenter is unavailable. Checking again in 5 seconds (a max of 40x)" 
           start-sleep 5
        }
        elseif ($statuscode -eq "Unable to connect to the remote server")
        {
            Write-Host "Unable to connect to vCenter. Checking again in 5 seconds (a max of 40x)" 
            start-sleep 5
        }
        else
        {
            Write-Host "Unable to connect to vCenter. Checking again in 5 seconds (a max of 40x)"
	    Write-Host "The status code is $statuscode"
            start-sleep 5
        }
    } 

    if ($webdata.Contains("The vSphere Client web server is still initializing"))
    {
        Write-Host "vCenter is still initializing (nearly ready)"
        start-sleep 5
    }
    elseif ($webdata.Contains("no healthy upstream")) 
    {
        Write-Host "vCenter is still initializing (nearly ready)"
        start-sleep 5
    }
    elseif ($webdata.Contains('<base href="/ui/">')) 
    {
        #Write-Host "vCenter is now able to accept requests"
        $vcenterready = $true
    }
    $attemptstoconnect++;
    if ($debug){write-host "Attempts to connect: $attemptstoconnect"}
    
} until (
    ($vcenterready) -or ($attemptstoconnect -gt 40)
)
######end area of trying to validate vcenter is up, or handling its waiting to come up####

  try
  {
    $keepTrying=$false
    $goodAccount=$false
    $msgPrompt="Please enter the vCenter Account"
    if ($debug) {Write-Host "Testing credentials to $serverIP"}
    
    # verify target directory is available
    $tmpdirexist = checkTargetDir $userFile
    if ($tmpdirexist) 
        {
            Write-Warning "Fatal error. Unable to create directory to store user and password data $tmpdirexist"
	    Write-Host "Run Puppet on this machine until it runs clean and make sure the account in use has write privs on the C:\Temp folder then re-run this script"
     	    Write-Host "The script will exit now"
			#no need to sleep here, if were already in error state
			#Start-Sleep 15
			#Read-Host -Prompt "Please press any key to continue or CTRL+C to quit" | Out-Null
            forceuserconsent
            exit
        }
    
    # check for password file already created
    if ([System.IO.File]::Exists($passFile) -and [System.IO.File]::Exists($userFile))
    {
        # Credentials Exist:
        $pwdEncBytes = Get-Content -Path $passFile -Encoding Byte
        $pwdDecBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $pwdEncBytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        $ppwd = [System.Text.Encoding]::ASCII.GetString($pwdDecBytes)
        $userName = Get-Content -Path $userFile -Encoding ASCII
        $pwdSec=$ppwd | ConvertTo-SecureString -AsPlainText -Force
        $psCred = New-Object System.Management.Automation.PSCredential -ArgumentList $userName,$pwdSec -ErrorAction Stop
        #test connection since we have uname and pw from file

        if (Test-Connection $serverIP -Quiet)
        {
            $vis=Connect-VIServer -Server $serverIP -Credential $psCred -ErrorAction SilentlyContinue
            if ($vis.isConnected)
            {
                $goodAccount=$true
                Disconnect-VIServer -Server $serverIP -Confirm:$False -ErrorAction SilentlyContinue
                if ($debug) {Write-Host "vCenter authentication was successful"}
            }
            else
            {
                Write-Warning "vCenter server $serverIP up but rejected connection: $vis"
            }
        }
        else 
        {
            Write-Warning "vCenter server $serverIP is not available for password confirmation"
            $goodAccount=$true
            $saveAccount=$false
        }

    }

    # No account (First time run) or password no longer valid
    if ($debug){Write-Host "goodAccount = " $goodAccount}

    if (!$goodAccount)
    {
        $userName=$defUserName
        $saveAccount = $true
        #Write-Host "Trying vCenter account: $userName"
        #open authentication creds input box
        do
        {
            $userPwdObj=Get-Credential -UserName $userName -Message $msgPrompt
            if ($null -ne $userPwdObj)
            {
                $bCred = $userPwdObj.GetNetworkCredential()
                # Update userName if needed
                $userName = $bCred.UserName
                $ppwd = $bCred.Password
                $pwdSec=$ppwd | ConvertTo-SecureString -AsPlainText -Force
                $psCred = New-Object System.Management.Automation.PSCredential -ArgumentList $userName,$pwdSec -ErrorAction Stop
                
                    if (Test-Connection $serverIP -Quiet)
                    {
                        # [System.Windows.MessageBox]::Show("Trying vCenter Account: $userName") | Out-Null
                        Write-Host "Trying vCenter account: $userName"
                        $vis=Connect-VIServer -Server $serverIP -Credential $psCred -ErrorAction SilentlyContinue
                        if ($vis.isConnected)
                        {
                            #this exits the while loop
                            $goodAccount=$true
                            #we disconnect to make sure its not he primary connection
                            Disconnect-VIServer -Server $serverIP -Confirm:$False -ErrorAction SilentlyContinue
                            Write-Host "Account authentication was successful"
                        }
                        #Write-Host "Account done"

                        if (!$goodAccount)
                        {
                            $msgAuthFail="vCenter Authentication failure.  Would you like to retry?"
                            $acctMsg="Account Authentication Failure"
                            Write-Warning "Account authentication failed. Try again?"
                            $respAuthFail=[System.Windows.MessageBox]::Show($msgAuthFail,$acctMsg,'YesNoCancel','Error')
                            $keepTrying=$false                    
                            if ($respAuthFail -eq "Yes")
                            {
                                $keepTrying=$true
                            }
                        }
                    }
                    else
                    {
                        $vCntrFail="vCenter $serverIP is not available. Proceed with saving account username/password without confirmation?"
                        $acctMsg="Server Connection Failure"
                        $skipCheck=[System.Windows.MessageBox]::Show($vCntrFail,$acctMsg,'YesNoCancel','Error')
                        if ($skipCheck -eq "Yes")
                        {
                            Write-Host "Saving credentials"
                            $goodAccount = $true
                            $saveAccount = $true
                        }
                        else {
                            Write-Host "Not saving credentials"
                            $goodAccount = $true
                            $saveAccount = $false
                        }
                    }
            }
        } while (!$goodAccount -AND $keepTrying)

        if ($goodAccount)
        {
            if ($saveAccount)
            {
                # Good Account - Encrypt and save password to file
                $pwdBytes = $ppwd.ToCharArray() | %{[byte] $_}
                $pwdEncBytes = [System.Security.Cryptography.ProtectedData]::Protect(
                $pwdBytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
                $pwdEncBytes | Set-Content -Path $passFile -Encoding Byte
                $userName | Set-Content -Path $userFile -Encoding ASCII
                Write-Host "Credentials saved"
            }
        }
        else
        {
            $psCred=$null
        }
    }
  }
  Catch 
  {
    Write-Warning "Login failed or vCenter is not available"
    # $wshell = New-Object -ComObject Wscript.Shell
    # $wshell.Popup("Login failed or vCenter is not available",0,"Done")
    [System.Windows.MessageBox]::Show("Login failed or vCenter is not available")
    throw $PSItem
  }
  return $psCred
}

# Get/Set Password Credentials from File
function getCredentials_esxi($passFile, $userFile, $defUserName, $serverIP)
{
  try
  {
    $keepTrying=$false
    $goodAccount=$false
    $msgPrompt="Please enter the ESXi Account"
    if ($debug) {Write-Host "Testing Credentials to ESXi server $serverIP"}
    
    # verify target directory is available
    $tmpdirexist = checkTargetDir $userFile
    if ($tmpdirexist) 
        {
            Write-Warning "Fatal error. Unable to create directory to store user and password data $tmpdirexist"
	    Write-Host "Run Puppet on this machine until it runs clean and make sure the account in use has write privs on the C:\Temp folder then re-run this script"
     	    Write-Host "The script will exit now"
			#Start-Sleep 15
			#Read-Host -Prompt "Please press any key to continue or CTRL+C to quit" | Out-Null
            forceuserconsent
            exit
        }
    
    # check for password file already created
    if ([System.IO.File]::Exists($passFile) -and [System.IO.File]::Exists($userFile))
    {
        # Credentials Exist:
        $pwdEncBytes = Get-Content -Path $passFile -Encoding Byte
        $pwdDecBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $pwdEncBytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        $ppwd = [System.Text.Encoding]::ASCII.GetString($pwdDecBytes)
        $userName = Get-Content -Path $userFile -Encoding ASCII
        $pwdSec=$ppwd | ConvertTo-SecureString -AsPlainText -Force
        $psCred = New-Object System.Management.Automation.PSCredential -ArgumentList $userName,$pwdSec -ErrorAction Stop
        #test connection since we have uname and pw from file

        if (Test-Connection $serverIP -Quiet)
        {
            $vis=Connect-VIServer -Server $serverIP -Credential $psCred -ErrorAction SilentlyContinue
            if ($vis.isConnected)
            {
                $goodAccount=$true
                Disconnect-VIServer -Server $serverIP -Confirm:$False -ErrorAction SilentlyContinue
                if ($debug) {Write-Host "ESXi authentication was successful"}
            }
            else
            {
                Write-Warning "ESXi server $serverIP up but rejected connection: $vis"
            }
        }
        else 
        {
            Write-Warning "ESXi server $serverIP not available for password confirmation"
            $goodAccount=$true
            $saveAccount=$false
        }

    }

    # No account (First time run) or password no longer valid
    if ($debug){Write-Host "goodAccount = " $goodAccount}

    if (!$goodAccount)
    {
        $userName=$defUserName
        $saveAccount = $true
        #Write-Host "Trying ESXi account: $userName"
        #open authentication creds input box
        do
        {
            $userPwdObj=Get-Credential -UserName $userName -Message $msgPrompt
            if ($null -ne $userPwdObj)
            {
                $bCred = $userPwdObj.GetNetworkCredential()
                # Update userName if needed
                $userName = $bCred.UserName
                $ppwd = $bCred.Password
                $pwdSec=$ppwd | ConvertTo-SecureString -AsPlainText -Force
                $psCred = New-Object System.Management.Automation.PSCredential -ArgumentList $userName,$pwdSec -ErrorAction Stop
                
                    if (Test-Connection $serverIP -Quiet)
                    {
                        # [System.Windows.MessageBox]::Show("Trying ESXi Account: $userName") | Out-Null
                        Write-Host "Trying ESXi account: $userName"
                        $vis=Connect-VIServer -Server $serverIP -Credential $psCred -ErrorAction SilentlyContinue
                        if ($vis.isConnected)
                        {
                            #this exits the while loop
                            $goodAccount=$true
                            #we disconnect to make sure its not he primary connection
                            Disconnect-VIServer -Server $serverIP -Confirm:$False -ErrorAction SilentlyContinue
                            Write-Host "Account authentication was successful"
                        }
                        #Write-Host "Account done"

                        if (!$goodAccount)
                        {
                            $msgAuthFail="ESXi Authentication failure.  Would you like to retry?"
                            $acctMsg="Account Authentication Failure"
                            Write-Warning "Account authentication failed. Try again?"
                            $respAuthFail=[System.Windows.MessageBox]::Show($msgAuthFail,$acctMsg,'YesNoCancel','Error')
                            $keepTrying=$false                    
                            if ($respAuthFail -eq "Yes")
                            {
                                $keepTrying=$true
                            }
                        }
                    }
                    else
                    {
                        $vCntrFail="ESXi $serverIP is not available. Proceed with saving account username/password without confirmation? "
                        $acctMsg="Server Connection Failure"
                        $skipCheck=[System.Windows.MessageBox]::Show($vCntrFail,$acctMsg,'YesNoCancel','Error')
                        if ($skipCheck -eq "Yes")
                        {
                            Write-Host "Saving credentials"
                            $goodAccount = $true
                            $saveAccount = $true
                        }
                        else {
                            Write-Host "Not saving credentials"
                            $goodAccount = $true
                            $saveAccount = $false
                        }
                    }
            }
        } while (!$goodAccount -AND $keepTrying)

        if ($goodAccount)
        {
            if ($saveAccount)
            {
                # Good Account - Encrypt and save password to file
                $pwdBytes = $ppwd.ToCharArray() | %{[byte] $_}
                $pwdEncBytes = [System.Security.Cryptography.ProtectedData]::Protect(
                $pwdBytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
                $pwdEncBytes | Set-Content -Path $passFile -Encoding Byte
                $userName | Set-Content -Path $userFile -Encoding ASCII
                Write-Host "Credentials saved"
            }
        }
        else
        {
            $psCred=$null
        }
    }
  }
  Catch 
  {
    Write-Warning "Login failed or ESXi is not available"
    # $wshell = New-Object -ComObject Wscript.Shell
    # $wshell.Popup("Login failed or vCenter is not available",0,"Done")
    [System.Windows.MessageBox]::Show("Login failed or ESXi is not available")
    throw $PSItem
  }
  return $psCred
}

# Get/Set Password Credentials from File
function getCredentials_netapp($passFile, $userFile, $defUserName, $serverIP)
{
  try
  {
    $keepTrying=$false
    $goodAccount=$false
    $msgPrompt="Please enter the NetApp Account"
    if ($debug) {Write-Host "Testing credentials to NetApp $serverIP"}
    
    # verify target directory is available
    $tmpdirexist = checkTargetDir $userFile
    if ($tmpdirexist) 
        {
            Write-Warning "Fatal error. Unable to create directory to store user and password data $tmpdirexist"
	    Write-Host "Run Puppet on this machine until it runs clean and make sure the account in use has write privs on the C:\Temp folder then re-run this script"
     	    Write-Host "The script will exit now"
            #dont sleep, already in error state
            #Start-Sleep 15
			#Read-Host -Prompt "Please press any key to continue or CTRL+C to quit" | Out-Null
            forceuserconsent
			exit
        }
    
    # check for password file already created
    if ([System.IO.File]::Exists($passFile) -and [System.IO.File]::Exists($userFile))
    {
        #$NetAppAdmin="admin"
        #$passfile="C:\temp\pwdNStore.txt"
        #$userfile="C:\temp\userNStore.txt"
        # Credentials Exist:
        $pwdEncBytes = Get-Content -Path $passFile -Encoding Byte
        $pwdDecBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $pwdEncBytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        $ppwd = [System.Text.Encoding]::ASCII.GetString($pwdDecBytes)
        $userName = Get-Content -Path $userFile -Encoding ASCII
        $pwdSec=$ppwd | ConvertTo-SecureString -AsPlainText -Force
        $psCred = New-Object System.Management.Automation.PSCredential -ArgumentList $userName,$pwdSec -ErrorAction Stop
        #test connection since we have uname and pw from file

        if (Test-Connection $serverIP -Quiet)
        {
            #use the netapp api to test auth


            # Get Nodes
            $url = "https://$serverIP/api/cluster/nodes"
            $nodes = Invoke-RestMethod -Method Get -Uri $url -Credential $pscred
            
            #if $nodes is an object, auth worked. else nope
            if ($nodes) {
                if ($debug) {Write-Host "NetApp authentication was successful"}
                $goodAccount=$true
            }
            else 
            {
                Write-Warning "NetApp server $serverIP up but failed authentication"
            }
        }
        else 
        {
            Write-Warning "NetApp server $serverIP is not available for authentication"
            $goodAccount=$true
            $saveAccount=$false
        }

    }

    # No account (First time run) or password no longer valid
    if ($debug){Write-Host "goodAccount = " $goodAccount}

    if (!$goodAccount)
    {
        $userName=$defUserName
        $saveAccount = $true
        #Write-Host "Trying Netapp Account: $userName"
        #open authentication creds input box
        do
        {
            $userPwdObj=Get-Credential -UserName $userName -Message $msgPrompt
            if ($null -ne $userPwdObj)
            {
                $bCred = $userPwdObj.GetNetworkCredential()
                # Update userName if needed
                $userName = $bCred.UserName
                $ppwd = $bCred.Password
                $pwdSec=$ppwd | ConvertTo-SecureString -AsPlainText -Force
                $psCred = New-Object System.Management.Automation.PSCredential -ArgumentList $userName,$pwdSec -ErrorAction Stop
                
                    if (Test-Connection $serverIP -Quiet)
                    {
                        #use the netapp api to test auth
                        # Get Nodes
                        $url = "https://$serverIP/api/cluster/nodes"
                        try {
                            $nodes = Invoke-RestMethod -Method Get -Uri $url -Credential $pscred -ErrorAction SilentlyContinue
                        }
                        catch {
                            write-Warning "NetApp authentication failed"
                        }
                        
                      

                        #if $ndoes is an object, auth worked. else nope
                        if ($nodes) {
                            Write-Host "NetApp authentication was successful"
                            $goodAccount=$true
                        }

                        if ($debug){write-host "goodaccount = $goodAccount "}
                        if (!$goodAccount)
                        {
                            $msgAuthFail="NetApp Authentication failure.  Would you like to retry?"
                            $acctMsg="NetApp Account Authentication Failure"
                            Write-Warning "NetApp authentication failed. Try again?"
                            $respAuthFail=[System.Windows.MessageBox]::Show($msgAuthFail,$acctMsg,'YesNoCancel','Error')
                            $keepTrying=$false                    
                            if ($respAuthFail -eq "Yes")
                            {
                                $keepTrying=$true
                            }
                        }
                    }
                    else
                    {
                        $vCntrFail="NetApp $serverIP is not available. Proceed with saving account username/password without confirmation? "
                        $acctMsg="NetApp Server Connection Failure"
                        $skipCheck=[System.Windows.MessageBox]::Show($vCntrFail,$acctMsg,'YesNoCancel','Error')
                        if ($skipCheck -eq "Yes")
                        {
                            Write-Host "Saving credentials"
                            $goodAccount = $true
                            $saveAccount = $true
                        }
                        else {
                            Write-Host "Not saving credentials"
                            $goodAccount = $true
                            $saveAccount = $false
                        }
                    }
            }
        } while (!$goodAccount -AND $keepTrying)

        if ($goodAccount)
        {
            if ($saveAccount)
            {
                # Good Account - Encrypt and save password to file
                $pwdBytes = $ppwd.ToCharArray() | %{[byte] $_}
                $pwdEncBytes = [System.Security.Cryptography.ProtectedData]::Protect(
                $pwdBytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
                $pwdEncBytes | Set-Content -Path $passFile -Encoding Byte
                $userName | Set-Content -Path $userFile -Encoding ASCII
                Write-Host "Credentials saved"
            }
        }
        else
        {
            $psCred=$null
        }
    }
  }
  Catch 
  {
    Write-Warning "Login failed or NetApp is not available"
    [System.Windows.MessageBox]::Show("Login failed or NetApp is not available")
    throw $PSItem
  }
  return $psCred
}


function startVCenter()
{
#try hard not to overcomplicate this. just check if its started, if not, start it
#return $true if it started
if (Test-Connection $ESXi1 -Quiet)
    {
        $psCred=getCredentials_esxi $pvfile $uvfile $userVName $ESXi1
        #cant very well start it, if we cannot get in esxi1 first.
        if ($null -eq $psCred)
        {
            throw [System.Security.Authentication.AuthenticationException] "ESXi 1 server authentication failure. Giving up"
            return $false
        }
        else 
        {
            #host is on, authentication passed, now connect to esxi1
            $vis=Connect-VIServer -Server $ESXi1 -Credential $psCred -ErrorAction SilentlyContinue
    		if ($vis.isConnected)
            {        
                    
                #is the vnia already on? needed for networking so top priority
                Write-Host "Checking if $vRouter1name is started (required for networking)"
                $vnia=Get-VM -Name $vRouter1name -ErrorAction SilentlyContinue
                if ($debug){Get-VM}
                Write-Host ""
                if ($debug){$vnia}
                if ($vnia.PowerState -match "PoweredOff")
                {
                    Write-Host "$vRouter1name is not running. Starting it (on ESXi1)"
                    Start-VM -VM $vRouter1name -Confirm:$False -ErrorAction Continue
                    Start-Sleep 8
                    $vniaObj=Get-VM -Name $vRouter1name -ErrorAction SilentlyContinue
                    if ($vniaObj.PowerState -match "PoweredOn")
                    {
                        #to fix output formating
                        Write-Host ""
                        Write-Host "$vRouter1name is running"
                    }
                    else {Write-Host "$vRouter1name is not running but we will check again soon"}
                }
                else {Write-Host "$vRouter1name is already running"}
                #ok, now for vcsa
                $vcsa=Get-VM -Name VCSA -ErrorAction SilentlyContinue
                if ($debug){Get-VM}
                Write-Host ""
                if ($debug){$vcsa}
                if ($vcsa.PowerState -match "PoweredOff")
                {
                    Write-Host "vCenter is not running. Starting it (on ESXi 1)"
                    Start-VM -VM VCSA -Confirm:$False -ErrorAction Continue
                    Write-Warning "Pausing for $vcenter_startup_seconds seconds for vCenter to start running"
                    Start-Sleep $vcenter_startup_seconds
    
                    $vcsaObj=Get-VM -Name VCSA -ErrorAction SilentlyContinue
                    if ($vcsaObj.PowerState -match "PoweredOn")
                    {
                        #to fix output formating
                        Write-Host ""
                        Write-Host "vCenter is running"
                        return $true
                    }
                }
                else 
                {
                    Write-Host "vCenter is already running"
                    return $true
                }
            }
            else 
            {
                Write-Warning "Unable to connect to ESXi 1"
                return $false
            }
        }
    }
    else 
    {
        Write-Warning "ESX1 is not pingable. The script cannot continue. Check power / network"
        throw [System.Security.Authentication.AuthenticationException] "ESX1 is not pingable. The script cannot continue. Check power / network"
        return $false
    }   
}






# Shut down vCenter
function shutdownVCenter()
{
    try
    {
        # Get ESXi VC Host Credentials
        $msgPrompt="Please enter the ESXi Account"
        
        $doNetApp=$False
        

        #use new mthod esxi specific
        #on lot g, vCenter should always be on host 1

        #$ESXiTarget=$vcHost

        $res = 0
        # Get vCenter Host First
        # $vcHost=(Get-VM -Name $vCenter -ErrorAction Continue).VMHost.Name
        if (!(isVCenterUp))
        {
            Write-Host "vCenter is already shut down"
        }
        else
        {
            #on lot g, vCenter should always be on host 1
            $psCred=getCredentials_vcenter $pvfile $uvfile $userVName $ESXi1
            $vcHost=$ESXi1

            if ($null -eq $psCred)
            {
                throw [System.Security.Authentication.AuthenticationException] "Authentication Failure, giving up"
            }

            #Write-Host "Disconnecting from vCenter"
            ## Disconnect vCenter First
            #Disconnect-VIServer -Server $vCenterIP -Confirm:$False -ErrorAction Continue

            Write-Host "Connecting to ESXi server $vcHost"
            # Connect to ESXi Host to issue vCenter Shut down
            $vis=Connect-VIServer -Server $vcHost -Credential $psCred -ErrorAction Continue

            if (Get-VM $vCenter -ErrorAction Continue | Where-Object {$_.PowerState -match "On"})
            {
                Write-Host "Shutting down vCenter"
                $res=Shutdown-VMGuest -VM $vCenter -Confirm:$False -ErrorAction Continue 
                start-sleep 2
                $resState=$res.State
                # $res=Stop-VM $vCenter -Confirm:$False -ErrorAction Continue | Select Guest, PowerState
				
                $waitForVCenterdown = $true
                while ($waitForVCenterdown)
                {
                    if ($debug){Write-Host "Pinging vCenter"}
                    
                    if (isVCenterUp)
                    {
                        if ($debug){Write-Host "vCenter is running"}
                        $waitForVCenterdown = $false
                    }
                    else
                    {
                        if ($debug){Write-Host "vCenter is not running"}
                        $waitForVCenterdown = $true
                        Start-Sleep 1
                    }
                }
                
				Write-Host "Completed vCenter shut down"
            }

            # Process done, disconnect from ESXi Host
            Write-Host "Disconnecting from ESXi server $vcHost"
            if ($debug){Write-Host "vCenter shut down results: $res"}
            Disconnect-VIServer -Server $vcHost -Confirm:$False -ErrorAction Continue
        }
        $ret = if ($resState -notmatch "Running") { $true } else { $false }
        return $ret
        }
    catch
    {
        Write-Warning "Error: Apparent problem shutting down vCenter.  $PSItem.ToString()"
        throw $PSItem
    }
}

function checkVCenter()
{
    #
    #  Start with check for vCenter up and available. Without vCenter up, nothing else can be done.
    #
    $vCenterDown=$False
    try
    {
        if (isVCenterUp)
        {
            # Is vCenter up and connecting? at this moment we know its at least pingable
            #get creds first, before trying to connect
            $msgPrompt="Please enter the vCenter Account"
            $doNetApp=$False

            #user new method vCenter specific
            $psCred = getCredentials_vcenter $pfile $ufile $userName $vCenterIP
            #nullify error if vCenter is not up

            Connect-VIServer -Server $vCenterIP -Credential $psCred -ErrorAction SilentlyContinue 
            
			#added  -Force -Confirm:$false because it was asking the user if they wanted to disco,. 
			#yes, thats why the command was here
            Disconnect-VIServer -Server $vCenterIP -Force -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    Catch [System.Security.Authentication.AuthenticationException]
    {
        Write-Warning "Certificate failure unexpected. vCenter is up: $($_.ToString())"
        Break
    }
    Catch [System.Web.Services.Protocols.SoapException]
    {
        Write-Warning "Login failure unexpected. vCenter is up: $($_.ToString())"
        Break
    }
    Catch 
    {
          Write-Warning "vCenter is not responding. Trying to start vCenter: $($_.ToString())"
          $vCenterDown=$True
    }
	#was previously commented, not sure why, uncommenting
    if ($vCenterDown)
    {
         #write-host "Running startvCenter"
         Write-Host "Starting vCenter"
         $vCenterDown=startVCenter
    }
    return $vCenterDown
}


# Shut down single ESXi host
function shutdownESXiHost_single($hosttoshutdown)
{
    #$vHosts = $ESXiHosts
    #$vCenterStarted=$False
    if ($hosttoshutdown -eq ""){Write-Warning "ERROR: No host to shut down was provided. Aborting"}
    # assume no connections and vCenter is down and
    # assume ESXi hosts are up - required for the vCenter to power up
    # Get ESXi Host Credentials
    #$msgPrompt="Please enter the ESXi Account"
    $ESXiTarget=$hosttoshutdown
 
    #use new method esxi specific
    
   
    $vh=$ESXiTarget
    Write-host "Connecting to ESXi server $vh"
    $ESXiConnected=$False

    if (Test-Connection $vh -Quiet)
    {
        $psCred=getCredentials_esxi $pvfile $uvfile $userVName $ESXiTarget
        if ($null -eq $psCred)
        {
            throw [System.Security.Authentication.AuthenticationException] "ESXi Authentication Failure, giving up"
            #we should never get here, the getcredentials function will ask them to make new ones if it fails etc. or end up with enough warnings.
        }

        $vis=Connect-VIServer -Server $vh -Credential $psCred -ErrorAction Continue
        if ($vis.isConnected)
        {
            $ESXiConnected=$True
        }
        else
        {
        Write-Warning "Connecting to ESXi server $vh failed"
        }
    }
    else 
    {
        Write-Host "The ESXi server $vh is already shut down"
        return $true
    }
	
	#if true, we authenticated to the ESXi host
    if ($ESXiConnected)
    {

        # Check for all VMs down     {$_.team -notlike "*ers*" -and $_.team -notlike "*ets*"}
	#ignore counting vCLS(special), the vtrc8000(needs hard shutdown), and MTISD (always lingers)
 	#if the count is above 0, it will interate waiting for them a few lines down.
         $vmCount=$(get-vm | Where-Object {$_.powerstate -eq "PoweredOn"} | Where-Object {$_.Name -notlike "vCLS*" -and $_.Name -notlike "*8000*" -and $_.Name -notlike "MTISD"} ).Count
            
        # Any lingering VMs?
        $attempts=10
        Write-Host "Checking if VMs are running on ESXi server $vh"
		Write-host "The script will check up to $attempts times"

            if ($vmCount -gt 0)
            {
                #$x=0
                for ($x=1; (($x -le $attempts) -xor ($vmCount -eq 0)); ++$x)
                {
                    #this needs to match the vmcount above, or we could end up with strange counts, handle the needed issues here first, for remaining vm's that we deal with differently
		    #like the vrtc8000 needs specific shutdown of hard, if were ignoring vcls and mtisd above, ignore it here too.
		    $vmCount=$(get-vm | Where-Object {$_.powerstate -eq "PoweredOn"} | Where-Object {$_.Name -notlike "vCLS*" -and $_.Name -notlike "*8000*" -and $_.Name -notlike "MTISD"} ).Count
                    Write-Host "The number of VMs running on ESXi server $vh is $vmCount"
                    # Try again nicely
                    Write-Host "This is attempt number $x to gently shut down all of the VMs on ESXi server $vh"
		    #we are not counting the MTISD here, but are sending the softshutdown to it, because its not in the -notlike list. It was also sent soft down by vcenter. its just problematic so we ask it again anyway.
      		    #we just dont count it, so that it does not hold up the whole thing. it will be asked nicely here, then forced below if its still running after this for loop code block. 
                    Get-VM | Where-Object {$_.powerstate -eq "PoweredOn"} | Where-Object {$_.Name -notlike "vCLS*" -and $_.Name -notlike "*8000*"} | Shutdown-VMGuest -Confirm:$false -ErrorAction SilentlyContinue
		    #since we know the vtrc8000 needs a hard shutdown do it here, before it gets to a lingering call below to help save time. No forced shutdowns happen until linger below
      		    Get-VM | Where-Object {$_.powerstate -eq "PoweredOn"} | Where-Object {$_.Name -like "*8000*"} | Stop-VM -Confirm:$false -ErrorAction SilentlyContinue
      		    # Give time for VMs to shut down
                    Start-Sleep $vmSleepDelay
                }

		#this block ideally has a 0 count, since they were stopped above, else they are stuck and need to be forced. really no need to filter anything except vCLS here
                #$vmCount2=$(Get-VM | Where-Object {$_.powerstate -eq "PoweredOn"}  | Measure-Object).Count
                $vmCount2=$(get-vm | Where-Object {$_.powerstate -eq "PoweredOn"} | Where-Object {$_.Name -notlike "vCLS*"}).Count
                if ($vmCount2 -gt 0)
                {
                Write-Host "The following $vmCount2 VMs would not shut down nice (via guest OS)" 
				Write-Host "so these VMs will be shut down with force"
                # For any still up, try harder - force VM Shut down:
		#really no need to filter anything except vCLS here
                #$lingeringvms = Get-VM | Where-Object {$_.powerstate -eq "PoweredOn"} | Where-Object {$_.Name -notlike "vCLS*" -and $_.Name -notlike "*8000*" -and $_.Name -notlike "MTISD"}
		$lingeringvms = Get-VM | Where-Object {$_.powerstate -eq "PoweredOn"} | Where-Object {$_.Name -notlike "vCLS*"}
                #Write-Host "Forcefully stopping the following VMs on $vh"
                Write-Host $lingeringvms
                Get-VM | Where-Object {$_.powerstate -eq "PoweredOn"} | Where-Object {$_.Name -notlike "vCLS*"} | Stop-VM -Confirm:$false -ErrorAction Continue
                }
                # Wait additionally for shut downs to complete, by now, its do or die, we tried to be nice. moving on
                Start-Sleep $vmSleepDelay
            }


  

    Write-Host "Shutting down ESXi server $vh"
        # No - not needed: Set-VMHost -VMHost $vh -State "Maintenance" -ErrorAction SilentlyContinue
    #Stop-VMHost -VMHost $vh -Confirm:$False -Force -ErrorAction Continue | Select-Object Guest, PowerState
    Stop-VMHost -VMHost $vh -Confirm:$False -Force -ErrorAction Continue
        
        # vCenter started, ESXI host required disconnect 
    Disconnect-VIServer -Server $vh -Confirm:$False -ErrorAction Continue
    } # isConnected
    else
    {
        Write-Warning "Connection failure to ESXi server $vh"
        #function only handles one ESXi now.
        #write-Warning "Continuing with the rest of the ESXi servers"
    }
    

    Write-Host "Confirming ESXi server $vh is shut down"
    
	$ServerName=$vh
        #Write-Host -NoNewline "Checking server {$ServerName}"
	# check for wait count, timeout after 90 seconds
        $CntDn=90
        while ((Test-Connection $vh -Quiet) -and ($CntDn -gt 0))
        {
            Write-Host -NoNewline "."
            Start-Sleep 1
	    --$CntDn
        }
	if ($CntDn -lt 1)
	{
	    Write-Host ""
	    Write-warning "ESXi server $ServerName has failed to shut down" 
            Write-Host "Log or console into the ESXi server $ServerName to investigate or re-run this script"
	    Write-Host "The script will exit now"
	    #Start-Sleep 15
		#Read-Host -Prompt "Press any key to continue or CTRL+C to quit" | Out-Null
        forceuserconsent
        exit
	}
	else
	{
	    Write-Host "."
	    Write-Host "Completed ESXi server $ServerName shut down"
        return $true
	}
    #in case something fails the if statements, return false
	Write-Host ""
	Write-warning "ESXi server $ServerName has failed to shut down" 
        Write-Host "Log or console into the ESXi server $ServerName to investigate or re-run this script"
	Write-Host "The script will exit now"
	#Start-Sleep 15
	#Read-Host -Prompt "Press any key to continue or CTRL+C to quit" | Out-Null
    forceuserconsent
    exit
}



#double check the netapp is ready for power off event.
#since its probably off, the test is to the two service processors on it, they SHOULD be at the same state
#a LOADER prompt on console
function verify_shutdownNetAppTR()
{
    
    #$NetAppAdmin="admin"
    #$pnfile="C:\temp\pwdNStore.txt"
    #$unfile="C:\temp\userNStore.txt"

	Write-Host "Checking if the NetApp controllers have shut down"
	Write-Host "NOTE: The script will check up to 10 times"
    $fileExist = Test-Path -Path 'C:\temp\pwdNStore.txt'
    $cmd = 'system log console'
	$cmd | Set-Content -Path 'C:\temp\vrifycmd.txt'

	$userName = 'admin'
	$userName | Set-Content -Path 'C:\temp\userNStore.txt'
    $nfile = "C:\temp\pwdNStore.txt"
	$pwdEncBytesN = Get-Content -Path $nfile -Encoding Byte
	$pwdDecBytesN = [System.Security.Cryptography.ProtectedData]::Unprotect(
	$pwdEncBytesN, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
	$netAppPwd = [System.Text.Encoding]::ASCII.GetString($pwdDecBytesN)

    #ssh to the service processors and run "system log console" to get all console logs,, we only want the last 10 or so. :(
    #very not happy with the netapp invoke-ncssh not working, due to security removing HMAC, and then, having a putty.exe from 2017, and then, not being able to add a real command line ssh client.
    #were using a gui to get output, forcing it to write to files and scan the files to get what should be normal output if it were a normal ssh command.

    #looking for the keywords of LOADER
    <#
    Portions Copyright (C) 2002-2023 NetApp, Inc. All Rights Reserved.

    ACPI RSDP Found at 0x68539000
    LOADER-A> BMC dcgsCluster-01>
#>
    #seek out the last 10 lines, then look for patterns
    #capture_Netapp_processor_logs $NetAppSP_IP1 $netAppPwd
    #capture_Netapp_processor_logs $NetAppSP_IP2 $netAppPwd
    
    $netappreadytopowerdown = 0
    $tries = 0

    #try to grab results, every 15 seconds, until both are true
    #set some values to 0 first.
    $netappcontroller1_readyforpowerdown = $false
    $netappcontroller2_readyforpowerdown = $false
    $netappreadyforpowerdown = $false
    do {
        #controller1, only retest if 0 to save time
        if ($netappcontroller1_readyforpowerdown -eq 0)
        {
            Write-Host "Checking NetApp controller 1 status"
            if (capture_Netapp_processor_logs $NetAppSP_IP1 $netAppPwd)
            {
                Write-Host "NetApp service processor $NetAppSP_IP1 is ready for power off"
                $netappcontroller1_readyforpowerdown = $true
                if ($debug){write-host "netappreadytopowerdown is " $netappreadytopowerdown}
            }
        }

        #controller2, only retest if 0 to save time
        if ($netappcontroller2_readyforpowerdown -eq 0)
        {
            Write-Host "Checking NetApp controller 2 status"
            if (capture_Netapp_processor_logs $NetAppSP_IP2 $netAppPwd)
            {
                Write-Host "NetApp service processor $NetAppSP_IP2 is ready for power off"
                $netappcontroller2_readyforpowerdown = $true
                if ($debug){write-host "netappreadytopowerdown is " $netappreadytopowerdown}
            }
        }

        
        start-sleep 15
        #we dont want to wait forver, $tries will try 10 * 15 seconds, may need adjustment
        $tries++
        if($debug){Write-Host "Checking if the NetApp controllers have shut down, $tries times"}
        Write-Host ""
        if ($debug){write-host "new netappreadytopowerdown is " $netappreadytopowerdown}
    } until (
        ((($netappcontroller1_readyforpowerdown) -and ($netappcontroller2_readyforpowerdown)) -or ($tries -eq 10))
    )

    #if this made it to two, we're good to shut down.
    if ((($netappcontroller1_readyforpowerdown) -and ($netappcontroller2_readyforpowerdown)) -and ($tries -lt 11) )
    {        
        Write-host "The NetApp controllers have shut down"
		#Start-Sleep 15
		#Read-Host -Prompt "Please press any key to continue or CTRL+C to quit" | Out-Null
        start-sleep 5
		return $true
    }
    else 
    {      #took too long, or something else was wrong, unable to tell
        Write-warning "The NetApp controllers did not shut down"
        Write-warning "The NetApp should be investigated before powering it off"
        $logfilepath1 ="C:\temp\"+$NetAppSP_IP1+".txt"
        $logfilepath2 ="C:\temp\"+$NetAppSP_IP2+".txt"
        Write-Host "Please review NetApp system logs at the path below before powering it off"
        Write-Host "$logfilepath1"
        Write-Host "$logfilepath2"
        Write-Host ""
	Write-Host "The script will exit now"
		#Start-Sleep 15
		#Read-Host -Prompt "Please press any key to continue or CTRL+C to quit" | Out-Null		
        forceuserconsent
        exit
    }
}

#this will pull the netapp service processor logs, and look for "LOADDER" in the last few lines, returns true or false
function capture_Netapp_processor_logs($service_processor_ip, $netAppPwd)
{
    if (($service_processor_ip -eq "") -or ($netAppPwd -eq ""))
    {
        Write-Warning "The service processor IP address or the NetApp password provided is blank"
	Write-Host "SSH into the NetApp service processors (if possible) to investigate or re-run this script"
 	Write-Host "The script will exit now"
		#3Start-Sleep 15
		#Read-Host -Prompt "Please press any key to continue or CTRL+C to quit" | Out-Null
        forceuserconsent
        exit
    }
    if (Test-Connection $service_processor_ip -Quiet)
    {
        #remove logfile, so putty doesnt complain about it
        $verify_logfilepath ="C:\temp\"+$service_processor_ip+".txt"

        if ($debug){write-host "service processor logfile path is $verify_logfilepath"}

        if (Test-Path -Path $verify_logfilepath)
        {Remove-Item -Path  $verify_logfilepath -Confirm:$false}
        #if (Test-Path -Path 'C:\temp\vrifylog2.txt')
        #{Remove-Item -Path 'C:\temp\vrifylog2.txt' -Confirm:$false}
        #sleep a short time, this is to help make it not look like its repeating forever. since larger sleeps were removed elsewhere
        start-sleep 3
        Write-Host "Checking NetApp service processor $service_processor_ip"
        Start-Process Putty.exe -Wait -ArgumentList "-ssh admin@$service_processor_ip -pw $netAppPwd -sessionlog $verify_logfilepath -m C:\temp\vrifycmd.txt"
        if (Get-Content -Tail 10 -Path $verify_logfilepath | Where-Object { ($_ -like "*LOADER*") -or ($_ -like "*System powering down*") })
        {
            write-host "NetApp service processor $service_processor_ip is halted"
            return $true
        }
        else {
            write-host "NetApp service processor $service_processor_ip is still halting"
            #write-warning "Do NOT power off the NetApp"
            return $false
        }
    }
    else 
    {
        Write-warning "Error pinging NetApp service processor IP address $service_processor_ip "  
	Write-Host "SSH into the NetApp service processors (if possible) to investigate or re-run this script"
        Write-Host "The script will exit now"
        #Write-warning "Possibly CB3 was switched off too soon"
		#no need to wait, already in error state
		#Start-Sleep 15
		#Read-Host -Prompt "Please press any key to continue or CTRL+C to quit" | Out-Null
        forceuserconsent
        exit
    }
}



function shutdownNetAppTR_API()
{
	$doNetApp=$true
	Write-Host "Shutting down NetApp"




    #not needed with api call
    #$cmd = 'node halt -node * -inhibit-takeover true -skip-lif-migration-before-shutdown true'
	#$cmd | Set-Content -Path 'C:\temp\cmd.txt'

    #if (Test-Path -Path 'C:\temp\shutdownlog.txt')
    #{Remove-Item -Path 'C:\temp\shutdownlog.txt' -Confirm:$false}


    #Write-Output y | pscp.exe -l admin -ls $NetAppIP 
	#Putty.exe -ssh admin@$NetAppIP -pw $netAppPwd -sessionlog C:\temp\shutdownlog.txt -m 'C:\temp\cmd.txt'
		

    ###new method to shut down api call
    # Get Nodes
    if (Test-Connection $NetAppIP)
    {
        $psCred=getCredentials_netapp $pnfile $unfile $NetAppAdmin $NetAppIP
        if ($null -eq $psCred)
        {
            throw [System.Security.Authentication.AuthenticationException] "NetApp authentication failure"
        }

        $url1 = "https://$NetAppIP/api/cluster/nodes"
        $nodes = Invoke-RestMethod -Method Get -Uri $url1 -Credential $psCred
        # Shut down Nodes
        $url2 = "https://$NetAppIP/api/private/cli/system/halt"
        $nodenumber=1
        foreach ( $node In $nodes.records ) {
            Write-Host "Shutting down NetApp node $nodenumber"
            $nodenumber++
            $body = @{
                'node' = "$($node.name)"
                'inhibit-takeover' = $true
                'skip-lif-migration-before-shutdown' = $true
                'ignore-quorum-warnings' = $true
            }
            #taken out, seems to make it act differently
            #           'power-off' = $true

            $body = $body | ConvertTo-Json -Depth 3

            try {
                Invoke-RestMethod -Method Post -Uri $url2 -Body $body -Credential $psCred -ErrorAction Continue
            }
            catch {
                Write-Warning "ERROR reported while attempting to shutdown NetApp: $($PSItem.ToString())" 
				Write-Host "SSH into the NetApp service processors (if possible) to investigate or re-run this script"
    		Write-Host "The script will exit now"
				#Start-Sleep 15
				#Read-Host -Prompt "Press any key to continue or CTRL+C to quit" | Out-Null
                forceuserconsent
		exit
                #probably better way to handle this
            } 

        }
        # Monitor Shut down 
        $waitcounter=0
        #this needs work, can make it wait for infinity if its not shutting down
        while ((Test-Connection $NetAppIP -Quiet) -and ($waitcounter -lt 10))
        {
            #Write-Host -NoNewline "."
            Write-Host "Please wait. NetApp is still in the process of shutting down."
            start-Sleep 3
            $waitcounter++
        }
    
        Write-Host "."
        Write-Host "NetApp is completing shut down process"
        Start-Sleep 30
        Write-Host "Completed NetApp shut down"

    }
    else 
    {
        Write-warning "NetApp address $NetAppIP is not reachable"
        Write-Host "Aborting request to shut down"
    }




		
}

function setupOutput()
{
  try
  {
    
  }
  catch
  {
        Write-Output "Error: $PSItem.ToString()"
        throw $PSItem
  }
}

function checkForShutdown()
{
        # During testing, this prompting led to the script hanging when it was started and 
        # forgotten to be answered:
        # $msgShutdownConfirm="Shutdown Process is about to start.  Press 'Yes' to start the shut down"
        # $scriptDone=[System.Windows.MessageBox]::Show($msgShutdownConfirm, 'Shut down Confirmation','YesNo','Warning')
        #
        # Doing this instead:
        # https://docs.microsoft.com/en-us/previous-versions/windows/internet-explorer/ie-developer/windows-scripting/x83z1d9f(v=vs.84)
        #
        #   0 - OK Button
        #   1 - OK and Cancel Buttons
        #   2 - Abort, Retry, Ignore Buttons
        #   3 - Yes, No, Cancel Buttons
        #   4 - Yes and No Buttons
        #   5 - Retry and Cancel Buttons
        #   6 - Cancel, Try Again, Continue Buttons
        #
        # Icon Types:
        #   16 - Stop Mark Icon
        #   32 - Question Mark Icon
        #   48 - Exclamation Mark Icon
        #   64 - Information Mark Icon
        #
        # Returns:
        #   -1 - Timeout
        #   1 - OK Button
        #   2 - Cancel Button
        #   3 - Abort Button
        #   4 - Retry Button
        #   5 - Ignore Button
        #   6 - Yes Button
        #   7 - No Button
        #   10 - Try Again Button
        #   11 - Continue Button
        #
        $ShutdownQ = New-Object -ComObject Wscript.Shell -ErrorAction Continue
        $ShutdownA = $ShutdownQ.popup("Shut down process will start in 15 seconds.  Press 'No' to cancel shut down", 15, "Shut down Confirmation", 4)

        # Default Timeout - continue shut down
        if ($ShutdownA -eq 7)
        {
            exit
        }
}

	

function testNetwork()
{
	$waitForNet = $true
	while ($waitForNet)
	{
        Write-Host "Checking for switch connectivity to $SWITCHGW"
		if (Test-Connection $SWITCHGW -Quiet)
		{
			Write-Host "Address is up"
            $waitForNet = $false
		}
		else
		{
			Write-Host "Waiting for Network to come up"
			$waitForNet = $true
			Start-Sleep 10
		}
	}
}

		

###########################################################
###                                                     ###
###     Initial Processing (Main) Section               ###
###                                                     ###
###########################################################



#the problem is that while we may be able to ask vCenter to start a vm, it will fail if the assigned host is down or not yet ready.
# :(

function check_vcenter_hosts_connections()
{
#	Name                 ConnectionState PowerState NumCpu CpuUsageMhz CpuTotalMhz   MemoryUsageGB   MemoryTotalGB Version
#----                 --------------- ---------- ------ ----------- -----------   -------------   ------------- -------
#10.6.70.102          NotResponding   Unknown        64           0      134336           0.000         511.719   7.0.3
#PS C:\ProgramData\StartDCGSA> get-vmhost | Where-Object ConnectionState -ne "Connected"    

	#get any status other than "Connected"
	if (checkVCenter)
	{
		if (connect_to_vcenter)
		{
			$badhosts = get-vmhost | Where-Object ConnectionState -ne "Connected"
			if ($badhosts.Count -eq 0)
			{
				return $true
			}
			else 
			{
				return $false
			}
		}
		else 
		{
		write-host "vCenter is pingable but cannot connect"
		return $false
		}
	}
	else {
		write-host "vCenter is not running"
		return $false
		}

}


function waitForGreenLotG_FULL()
{

	
        # Create the the initial output
		$here_string = @"
        ----------------------------------------
        Standby. Testing readiness: FULL OP mode
        ----------------------------------------
        ESXi1  status           = Checking..
        ESXi2  status           = Checking..
        ESXi3  status           = Checking..
        NetApp status           = Checking..
        ----------------------------------------
        Cancel with 'Ctrl c'  
        ----------------------------------------
"@

        Clear-Host
        write-host $here_string

        #set defaults
		$esxi1pingable = $false
        $esxi2pingable = $false
        $esxi3pingable = $false
        $netapppingable = $false

	$waitForStartup = $true		
	while ($waitForStartup)
	{


        if (Test-Connection $ESXi1 -Count 1 -Delay 1 -Quiet)
            {
                $esxi1pingable = $true
        $here_string = @"
        ----------------------------------------
        Standby. Testing readiness: FULL OP mode
        Waiting for the these to be pingable
        ----------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ----------------------------------------
        Cancel with 'Ctrl c'
        ----------------------------------------
"@
            Clear-Host
            write-host $here_string
            }
            else 
            {
            $esxi1pingable = $false
        $here_string = @"
        ----------------------------------------
        Standby. Testing readiness: FULL OP mode
        Waiting for the these to be pingable
        ----------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ----------------------------------------
        Cancel with 'Ctrl c'
        ----------------------------------------
"@
            Clear-Host
            write-host $here_string
            }

        if (Test-Connection $ESXi2 -Count 1 -Delay 1 -Quiet)
            {
                $esxi2pingable = $true
        $here_string = @"
        ----------------------------------------
        Standby. Testing readiness: FULL OP mode
        Waiting for the these to be pingable
        ----------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ----------------------------------------
        Cancel with 'Ctrl c'
        ----------------------------------------
"@
            Clear-Host
            write-host $here_string
            }
            else 
            {
            $esxi2pingable = $false
        $here_string = @"
        ----------------------------------------
        Standby. Testing readiness: FULL OP mode
        Waiting for the these to be pingable
        ----------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ----------------------------------------
        Cancel with 'Ctrl c'
        ----------------------------------------
"@
            Clear-Host
            write-host $here_string
            }

        if (Test-Connection $ESXi3 -Count 1 -Delay 1 -Quiet)
            {
                $esxi3pingable = $true
        $here_string = @"
        ----------------------------------------
        Standby. Testing readiness: FULL OP mode
        Waiting for the these to be pingable
        ----------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ----------------------------------------
        Cancel with 'Ctrl c'
        ----------------------------------------
"@
            Clear-Host
            write-host $here_string
            }
            else 
            {
            $esxi3pingable = $false
        $here_string = @"
        ----------------------------------------
        Standby. Testing readiness: FULL OP mode
        Waiting for the these to be pingable
        ----------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ----------------------------------------
        Cancel with 'Ctrl c'
        ----------------------------------------
"@
            Clear-Host
            write-host $here_string
            }

        if (Test-Connection $NetAppIP -Count 1 -Delay 1 -Quiet)
            {
                $netapppingable = $true
        $here_string = @"
        ----------------------------------------
        Standby. Testing readiness: FULL OP mode
        Waiting for the these to be pingable
        ----------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ----------------------------------------
        Cancel with 'Ctrl c'
        ----------------------------------------
"@
            Clear-Host
            write-host $here_string
            }
            else 
            {
            $netapppingable = $false
        $here_string = @"
        ----------------------------------------
        Standby. Testing readiness: FULL OP mode
        Waiting for the these to be pingable
        ----------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ----------------------------------------
        Cancel with 'Ctrl c'
        ----------------------------------------
"@
            Clear-Host
            write-host $here_string
            }


        #check the results of pings above
		if (($netapppingable) -AND ($esxi1pingable) -AND ($esxi2pingable) -AND ($esxi3pingable))
		{
		#all are true, we passed!, display then move out of loop setting waitForStartup to false
		$here_string = @"
        ----------------------------------------
        Standby. Ready to proceed.
        
        ----------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ----------------------------------------
        Cancel with 'Ctrl c'  ..Proceeding..
        ----------------------------------------
"@
			$waitForStartup = $true
            Clear-Host
            write-host $here_string
			Start-Sleep 3
			#ok we showed the screen for 3 seconds, exit the loop so we can continue
			$waitForStartup = $false
		}
		else
		{
			#Write-Host "Make sure these are powered on"
            # Create the here-string
$here_string = @"
        ----------------------------------------
        Standby. Testing readiness: FULL OP mode
        Waiting for the these to be pingable
        ----------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ----------------------------------------
        Cancel with 'Ctrl c'  ..Retrying..
        ----------------------------------------
"@
			$waitForStartup = $true
            Clear-Host
            write-host $here_string
			Start-Sleep 1
		}
	}	
	#send true as if $waitForStartup is false, meaning its ready to start
	if (!$waitForStartup) {return $true}
	else 
	{#should never happen, but still
		return $false
	}
}	


#this function will shut down in this order
#if vCenter up, all full and otm vm in reverse order (except vcsa)
#host3, host2, host1, netapp
function waitForGreenLotG_shutdown_from_OTM_or_FULL()
{

	
        # Create the the initial output
		$here_string = @"
        ---------------------------------------
        Standby. Determining system status
        (shutting down)
        ---------------------------------------
        ESXi1  status           = Checking..
        ESXi2  status           = Checking..
        ESXi3  status           = Checking..
        NetApp status           = Checking..
        ---------------------------------------
        Cancel with 'Ctrl c'  
        ---------------------------------------
"@

        Clear-Host
        write-host $here_string
        #set defaults

        $esxi1pingable = $false
        $esxi2pingable = $false
        $esxi3pingable = $false
        $netapppingable = $false
		
	$waitForStartup = $true		
	while ($waitForStartup)
	{

        if (Test-Connection $ESXi1 -Count 1 -Delay 1 -Quiet)
            {
            $esxi1pingable = $true
            Clear-Host
            $here_string = @"
        ---------------------------------------
        Standby. Determining system status
        (shutting down)
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'
        ---------------------------------------
"@
        write-host $here_string
            }
		else 
			{
			$esxi1pingable = $false
			Clear-Host
			$here_string = @"
        ---------------------------------------
        Standby. Determining system status
        (shutting down)
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'
        ---------------------------------------
"@
			}

        if (Test-Connection $ESXi2 -Count 1 -Delay 1 -Quiet)
            {
            $esxi2pingable = $true
            Clear-Host
            $here_string = @"
        ---------------------------------------
        Standby. Determining system status
        (shutting down)
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'
        ---------------------------------------
"@
            write-host $here_string
            }
		else 
			{
			$esxi2pingable = $false
			Clear-Host
			$here_string = @"
        ---------------------------------------
        Standby. Determining system status
        (shutting down)
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'
        ---------------------------------------
"@
			}

        if (Test-Connection $ESXi3 -Count 1 -Delay 1 -Quiet)
            {
            $esxi3pingable = $true
            Clear-Host
            $here_string = @"
        ---------------------------------------
        Standby. Determining system status
        (shutting down)
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'
        ---------------------------------------
"@
            write-host $here_string
            }
		else 
			{
			$esxi3pingable = $false
			Clear-Host
			$here_string = @"
        ---------------------------------------
        Standby. Determining system status
        (shutting down)
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'
        ---------------------------------------
"@
			}
#netapp?
        if (Test-Connection $NetAppIP -Count 1 -Delay 1 -Quiet)
            {
            $netapppingable = $true
            Clear-Host
            $here_string = @"
        ---------------------------------------
        Standby. Determining system status
        (shutting down)
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'
        ---------------------------------------
"@
            write-host $here_string
            }
		else 
			{
			$netapppingable = $false
			Clear-Host
			$here_string = @"
        ---------------------------------------
        Standby. Determining system status
        (shutting down)
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'
        ---------------------------------------
"@
			}
			
        #check the results of pings above

			$waitForStartup = $true
            Clear-Host
			$here_string = @"
        ---------------------------------------
        Standby. Determining system status
        (shutting down)
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'
        ---------------------------------------
"@
        write-host $here_string

        #stop Full then OTM list first using vCenter. (not vCenter though)
        if ((isVCenterUp) -and (Test-Connection $ESXi1 -Quiet))
        {
            if ($debug) 
            {
            write-host "vCenter and ESX 1 are running. Using vCenter to shut down most VMs"
			write-host "ESXi 1 and vCenter (on ESXi 1) are running"
			write-host "Shutting down VMs listed in Full Operation VM name list"
            }  
            stop_FULL_vms
            
            if ($debug){write-host "Shutting down VMs listed in OTM Operation VM name list"}
            stop_OTM_vms
    }
##############end shut down Full and OTM################

        #stop esxi 3  and esxi 2 if running
        if ($esxi3pingable)
        {
            if ($debug) {write-host "ESXi 3 is running. Shutting it down"}
            if (Test-Connection $ESXi3 -Quiet)
            {
                $host3power = shutdownESXiHost_single $ESXi3


                if (Test-Connection $ESXi3 -Quiet)
                {
                    $esxi3pingable = $true
                }
                else
                {
                    $esxi3pingable = $false
                }
                
            }
        }
        else 
        {
            if ($debug)
            {
                Write-Host "ESXi 3 is not pingable"
            }
            $esxi3pingable = $false
        }
        
        Clear-Host
        $here_string = @"
        ---------------------------------------
        Standby. Determining system status
        (shutting down)
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'
        ---------------------------------------
"@
            write-host $here_string
##############end shut down esxi3################

            if ($esxi2pingable)
            {
                if ($debug) {write-host "ESXi 2 is running. Shutting it down"}
                if (Test-Connection $ESXi2 -Quiet)
                {
                    $host2power = shutdownESXiHost_single $ESXi2
                    if (Test-Connection $ESXi2 -Quiet)
                    {
                        $esxi2pingable = $true
                    }
                    else
                    {
                        $esxi2pingable = $false
                    }
                }
            }
            else 
            {
                if ($debug)
                {
                    Write-Host "ESXi 2 is not pingable"
                }
                $esxi2pingable = $false
            }

            Clear-Host
			$here_string = @"
        ---------------------------------------
        Standby. Determining system status
        (shutting down)
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'
        ---------------------------------------
"@
        write-host $here_string
##############end shut down esxi2################

		#stop exi1 if its up
            if ($esxi1pingable)
            {
                if ($debug) {write-host "ESXi 1 is running. Shutting it down"}
                if (Test-Connection $ESXi1 -Quiet)
                {
                    $host1power = shutdownESXiHost_single $ESXi1

                    if (Test-Connection $ESXi1 -Quiet)
                    {
                        $esxi1pingable = $true
                    }
                    else
                    {
                        $esxi1pingable = $false
                    }
                }
            }
            else 
            {
                if ($debug)
                {
                    Write-Host "ESXi 1 is not pingable"
                }
                $esxi1pingable = $false
            }
			
            Clear-Host
			$here_string = @"
        ---------------------------------------
        Standby. Determining system status
        (shutting down)
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'
        ---------------------------------------
"@
        write-host $here_string
##############end shut down esxi1################

##############all esxi down, shut down NetApp if its up#############
			if (Test-Connection $NetAppIP -Quiet)
			{
				$netapppingable = $true
			}
			else
			{
				$netapppingable = $false
			}
			#finally, shut off the netapp
            if (($netapppingable) -AND (!($esxi2pingable) -AND !($esxi3pingable)))
            {
                if ($debug) {Write-Host "NetApp is running. Shutting it down"}
                shutdownNetAppTR_API
                #double check the netapp is ready for power off event.
                #since its probably off, the test is to the two service processors on it, they SHOULD be at the same state
                #a LOADER prompt on console

                $netAppReady_for_powerloss = verify_shutdownNetAppTR
                if($netAppReady_for_powerloss)
                {
                    $netapppingable = $false
                }
                else 
                {
                    $netapperror = $true
					Write-Warning "ERROR: The NetApp is in an unexpected state"
					Write-Host "Please review the logs in the paths below before powering it off"
					Write-Host "C:\temp\vrfylog1.txt and vrfylog2.txt"
     					Write-Host "The script will exit now"
					#Start-Sleep 15
					#Read-Host -Prompt "Press any key to continue or CTRL+C to quit" | Out-Null
                    forceuserconsent
		    exit
                }
            }


		if (!($netapppingable) -AND !($esxi1pingable) -AND !($esxi2pingable) -AND !($esxi3pingable))
		{
		#all are true, we passed!, display then move out of loop setting waitForStartup to false
		$here_string = @"
        ---------------------------------------
        Standby. Determining system status
        (shutting down)
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'  ..Proceeding..
        ---------------------------------------
"@
			$waitForStartup = $true
            Clear-Host
            write-host $here_string
			Start-Sleep 1
			#ok we showed the screen for 3 seconds, exit the loop so we can continue
			$waitForStartup = $false
		}
		else
		{
			#Write-Host "Make sure these are powered on"
            # Create the here-string
$here_string = @"
        ---------------------------------------
        Standby. Determining system status
        (shutting down)
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'  ..Retrying..
        ---------------------------------------
"@
			$waitForStartup = $true
            Clear-Host
            write-host $here_string
			Start-Sleep 1
		}
	}	
	#send true as if $waitForStartup is false, meaning its ready to start
	if (!$waitForStartup) {return $true}
	else 
	{#should never happen, but still
		return $false
	}
}


function waitForGreenLotG_OTM()
{

	
        # Create the the initial output
		$here_string = @"
        ---------------------------------------
        Standby. Testing readiness: OTM mode
        ---------------------------------------
        ESXi1  status           = Checking..
        ESXi2  status           = Checking..
        ESXi3  status           = Checking..
        NetApp status           = Checking..
        ---------------------------------------
        Cancel with 'Ctrl c'  
        ---------------------------------------
"@

        Clear-Host
        write-host $here_string
        #set defaults

        $esxi1pingable = $false
        $esxi2pingable = $false
        $esxi3pingable = $false
        $netapppingable = $false
		
	$waitForStartup = $true		
	while ($waitForStartup)
	{

        if (Test-Connection $ESXi1 -Count 1 -Delay 1 -Quiet)
            {
                $esxi1pingable = $true
                $here_string = @"
        ---------------------------------------
        Standby. Testing readiness: OTM mode
        Waiting for only ESXi1 to be pingable
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'
        ---------------------------------------
"@              
                Clear-Host
                write-host $here_string
            }
			else 
			{
			$esxi1pingable = $false
			$here_string = @"
        ---------------------------------------
        Standby. Testing readiness: OTM mode
        Waiting for only ESXi1 to be pingable
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'
        ---------------------------------------
"@
            Clear-Host
            write-host $here_string
			}

        if (Test-Connection $ESXi2 -Count 1 -Delay 1 -Quiet)
            {
            $esxi2pingable = $true
            Clear-Host
            $here_string = @"
        ---------------------------------------
        Standby. Testing readiness: OTM mode
        Waiting for only ESXi1 to be pingable
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'
        ---------------------------------------
"@
            Clear-Host
            write-host $here_string
            }
			else 
			{
			$esxi2pingable = $false

			$here_string = @"
        ---------------------------------------
        Standby. Testing readiness: OTM mode
        Waiting for only ESXi1 to be pingable
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'
        ---------------------------------------
"@
            Clear-Host
            write-host $here_string
			}

        if (Test-Connection $ESXi3 -Count 1 -Delay 1 -Quiet)
            {
            $esxi3pingable = $true
            $here_string = @"
        ---------------------------------------
        Standby. Testing readiness: OTM mode
        Waiting for only ESXi1 to be pingable
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'
        ---------------------------------------
"@
            Clear-Host
            write-host $here_string
            }
			else 
			{
			$esxi3pingable = $false
			$here_string = @"
        ---------------------------------------
        Standby. Testing readiness: OTM mode
        Waiting for only ESXi1 to be pingable
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'
        ---------------------------------------
"@
            Clear-Host
            write-host $here_string
			}

        if (Test-Connection $NetAppIP -Count 1 -Delay 1 -Quiet)
            {
            $netapppingable = $true
            $here_string = @"
        ---------------------------------------
        Standby. Testing readiness: OTM mode
        Waiting for only ESXi1 to be pingable
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'
        ---------------------------------------
"@
            Clear-Host
            write-host $here_string
            }
			else 
			{
			$netapppingable = $false
			$here_string = @"
        ---------------------------------------
        Standby. Testing readiness: OTM mode
        Waiting for only ESXi1 to be pingable
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'
        ---------------------------------------
"@
            Clear-Host
            write-host $here_string
			}
			
        #check the results of pings above

			$waitForStartup = $true
			$here_string = @"
        ---------------------------------------
        Standby. Testing readiness: OTM mode
        Waiting for only ESXi1 to be pingable
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'
        ---------------------------------------
"@
            Clear-Host
            write-host $here_string

            #stop esxi 3  and esxi 2 if running
            if ($esxi3pingable)
            {
                if ($debug) {write-host "ESXi 3 is running. Shutting it down"}
                if (Test-Connection $ESXi3 -Count 1 -Delay 1 -Quiet)
                {
                    $host3power = shutdownESXiHost_single $ESXi3
                    if ($host3power){}

                    if (Test-Connection $ESXi3 -Count 1 -Delay 1 -Quiet)
                    {
                        $esxi3pingable = $true
                    }
                    else
                    {
                        $esxi3pingable = $false
                    }
                }
            }
            else 
            {
                if ($debug)
                {
                    Write-Host "ESXi 3 is not pingable"
                }
            }

            
            if ($esxi2pingable)
            {
                if ($debug) {write-host "ESXi 2 is running. Shutting it down"}
                if (Test-Connection $ESXi2 -Count 1 -Delay 1 -Quiet)
                {
                    $host2power = shutdownESXiHost_single $ESXi2
                    if ($host2power){}

                    if (Test-Connection $ESXi2 -Count 1 -Delay 1 -Quiet)
                    {
                        $esxi2pingable = $true
                    }
                    else
                    {
                        $esxi2pingable = $false
                    }
                }
            }
            else 
            {
                if ($debug)
                {
                    Write-Host "ESXi 2 is not pingable"
                }
            }



			

			if (Test-Connection $NetAppIP -Count 1 -Delay 1 -Quiet)
			{
				$netapppingable = $true
			}
			else
			{
				$netapppingable = $false
			}
			
			
			#finally, shut off the netapp
            if (($netapppingable) -AND (!($esxi2pingable) -AND !($esxi3pingable)))
            {
                Write-Host "NetApp is running. Shutting it down"
                Write-Host "NOTE: OTM Operation just uses ESXi 1"
                shutdownNetAppTR_API
                #double check the netapp is ready for power off event.
                #since its probably off, the test is to the two service processors on it, they SHOULD be at the same state
                #a LOADER prompt on console
                
                
                $netAppReady_for_powerloss = verify_shutdownNetAppTR
                if($netAppReady_for_powerloss)
                {
                    $netapppingable = $false
                }
                else 
                {
                    $netapperror = $true
					Write-Warning "ERROR: The NetApp is in an unexpected state"
					Write-Host "Please review the logs in the paths below before powering it off"
					Write-Host "C:\temp\vrfylog1.txt and vrfylog2.txt"
     					Write-Host "The script will exit now"
					#Start-Sleep 15
					#Read-Host -Prompt "Press any key to continue or CTRL+C to quit" | Out-Null
                    forceuserconsent
		    exit
                }
            }


		if (!($netapppingable) -AND ($esxi1pingable) -AND !($esxi2pingable) -AND !($esxi3pingable))
		{
		#all are true, we passed!, display then move out of loop setting waitForStartup to false
		$here_string = @"
        ---------------------------------------
        Standby. Ready to proceed. 
        
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'  ..Proceeding..
        ---------------------------------------
"@
			$waitForStartup = $true
            Clear-Host
            write-host $here_string
			Start-Sleep 1
			#ok we showed the screen for 3 seconds, exit the loop so we can continue
			$waitForStartup = $false
		}
		else
		{
			#Write-Host "Make sure these are powered on"
            # Create the here-string
$here_string = @"
        ---------------------------------------
        Standby. Testing readiness: OTM mode
        Waiting for only ESX1 to be pingable
        ---------------------------------------
        ESXi1  status           = $esxi1pingable
        ESXi2  status           = $esxi2pingable
        ESXi3  status           = $esxi3pingable
        NetApp status           = $netapppingable
        ---------------------------------------
        Cancel with 'Ctrl c'  ..Retrying..
        ---------------------------------------
"@
			$waitForStartup = $true
            Clear-Host
            write-host $here_string
			Start-Sleep 1
		}
	}	
	#send true as if $waitForStartup is false, meaning its ready to start
	if (!$waitForStartup) {return $true}
	else 
	{#should never happen, but still
		return $false
	}
}	


#expects the 3 esxi to be on, and the netapp. 
#will start vCenter and the vRouter1 on esxi1 if needed, then start otm vm, then start full vm list
function Start-to-full-operation()
{

    #first, make sure the systems are up enough to try to start
    Write-Host "Checking if the servers required for Full Operation mode are running"
    Write-Host "NOTE: This requires ESXi servers 1, 2, 3 and the NetApp to be running"
	#returns true when all hosts and netapp are alive, should not return false, maybe under an aborted session?
	if (waitForGreenLotG_FULL)
		{	###
			#check if vCenter is alive, if not might as well get into esxi1, and start it, assuming its powered off
			#if that is the case, also power on the rest of the OTM vm's since they should have started automatically
			#once those are up, we can startup the rest via vCenter
			

            #vCenter is pingable, try to auth (this will auth, and fix or store auth, returns if vCenter is actually up or not.
            #if false return, try to start it 
            write-host	"Checking vCenter credentials"
			if (checkVCenter) 
			{

				#vCenter started, now power on the others, which will fail if they are already on.
				#were going for OTM first, then full operation
                if ($debug)
                {
                    write-host "vCenter appears to be working and authenticated"
                    write-host ""
                }
				
				#most of the logic is put into the two below function, for time saving, not duplicating start events on running vm, etc.
				start_OTM_vms
				write-host "The VMs in the OTM Operation VM name list are running"
                write-host ""
				if (check_vcenter_hosts_connections)
				{
				$hostsready=$true
				write-host "The ESXi servers are running (according to vCenter)"
				}
				else
				{
					$timeoutvar = 0
					do
					{
						$hostsready = check_vcenter_hosts_connections
						write-host	"vCenter is reporting that an ESXi server is not running. Re-checking in 20 seconds (max of 5 min)"
						#get-vmhost | Where-Object ConnectionState -eq "Connected" | Select-Object Name, ConnectionState, PowerState 
						$stats = get-vmhost | Select-Object Name, ConnectionState, PowerState | Sort-Object
						$stats | Format-Table | Out-String | % {Write-Host $_}
						start-sleep 5
						write-host -nonewline "."
						$timeoutvar = $timeoutvar + 5
						start-sleep 5
						write-host -nonewline "."
						$timeoutvar = $timeoutvar + 5
						start-sleep 5
						write-host -nonewline "."
						$timeoutvar = $timeoutvar + 5
						start-sleep 5
						write-host -nonewline "."
						$timeoutvar = $timeoutvar + 5
						#write-host "timeoutvar is " $timeoutvar
						#write-host "hostready is " $hostsready
					}
					until (($hostsready) -or ($timeoutvar -gt 300))
					
				}

				if ($hostsready)
				{
					start_FULL_vms
					#write-host "Completed start to Full Operation mode"
     					#Write-Host "The script has completed and will now return to the main menu"
	  
					#start-sleep 15
					#Read-Host -Prompt "Press any key to continue or CTRL+C to quit" | Out-Null
                    #forceuserconsent
				}
				else
				{
					write-warning "One or more ESXi servers are not running"
					write-Host "Resolve the issue with vCenter (on ESXi 1) and/or the ESXi servers then re-run this script"
     					Write-Host "The script will exit now"
					#no need to sleep, error is already present and they have to hit a key
					#start-sleep 15
					#Read-Host -Prompt "Press any key to continue or CTRL+C to quit" | Out-Null
                    forceuserconsent
					exit 1
				}
 
            }
            else 
            {
            write-warning "Failed to start vCenter"
	    Write-Host "Log into ESXi 1 and start it (if possible) then re-run this script"
     	    Write-Host "The script will exit now"
			#no need to sleep, error is already present and they have to hit a key
			#start-sleep 15
			#Read-Host -Prompt "Press any key to continue or CTRL+C to quit" | Out-Null
            forceuserconsent
            exit
            }
		}
}



#expects the 1 esxi to be on, and nothing else.
#in fact, it will stop other items running if they are found to be up, like ESXi host 2 and 3, and the netapp
#will also start vCenter and the vRouter1 on esxi1 if needed, then start otm vm, then start otm vm list
function Start-to-otm-operation()
{

    #first, make sure the systems are up enough to try to start
    Write-Host "Checking if the servers required for OTM Operation mode are running"
    Write-Host "NOTE: This just requires ESXi server 1 to be running"
	#returns true when only the esxi1 is pingable, should not return false, maybe under an aborted session?
    #this will also stop the esxi host 2 and 3, and netapp if found to be running
	if (waitForGreenLotG_OTM)
		{	###
			#check if vCenter is alive, if not might as well get into esxi1, and start it, assuming its powered off
			#if that is the case, also power on the rest of the OTM vm's since they should have started automatically
			#once those are up, we can startup the rest via vCenter
			

            #vCenter is pingable, try to auth (this will auth, and fix or store auth, returns if vCenter is actually up or not.
            #if false return, try to start it 
            write-host "Checking vCenter credentials"
			if (checkVCenter) 
			{
				#vCenter started, now power on the others, which will fail if they are already on.
				#were going for OTM first, 
                if ($debug)
                {
                    write-host "vCenter appears to be working and authenticated"
                    write-host "vCenter operation appears to be working"
                    write-host "Task is OTM operation"
                    write-host "Checking status of OTM VMs first"
                    write-host "Checking / Starting VM list"
                    write-host ""
                }
				
				#most of the logic is put into the two below function, for time saving, not duplicating start events on running vm, etc.
				start_OTM_vms
				#write-host "Completed start to OTM Operation mode"
    				#write-Host "The script has completed and will now return to the main menu"
				#start-sleep 15
				#Read-Host -Prompt "Press any key to continue or CTRL+C to quit" | Out-Null
                #forceuserconsent
            }
            else 
            {
            write-warning "Failed to start vCenter"
	    write-host "Log into ESXi 1 and start it (if possible) then re-run this script"
            write-host "The script will exit now"
			#no need to sleep, error already present
			#start-sleep 15
			#Read-Host -Prompt "Press any key to continue or CTRL+C to quit" | Out-Null
            forceuserconsent
            exit
            }
		}
}




#makes lists of running vCenter vm, compares to list desired, only starts ones that are not already running
#has flag to speed up the start for FULL, no flag for OTM as they have some dependencies in start ordering
function start_FULL_vms()
{
	$FULL_vms=getFULL_vmlist
	if ($debug)
    {write-host $FULL_vms}
	#lets get the status of each match from vCenter, so we can save time and only start ones not started
	$vcentervms = getvcentervmlist
    write-host ""
	write-host "Starting" $FULL_vms.Count "VMs from the FULL Operation VM name list"
	$fullvmscount=$FULL_vms.Count
	#write-host $FULL_vms.Count "VM listed for FULL mode"
	#create list
	$fullstartlist = New-Object 'System.collections.generic.list[System.object]'
	$full_vm_already_running=0
	for ($full=0; $full -lt $FULL_vms.Count; ++$full)
	{
		$vm=$FULL_vms[$full]
		if ($vcentervms.Name -eq $vm)
		{
			$pwrstate=($vcentervms|where-object Name -eq $vm).PowerState
			$resp = "VMS[$full]: $vm State: $pwrstate -- unknown power state?"
			#Write-Host $resp
			if ($pwrstate -match "PoweredOff")
			{
			$resp = "VMS[$full]: $vm State: $pwrstate -- Added to start list"
			$fullstartlist.add("$vm")
			}
			elseif ($pwrstate -match "PoweredOn")
			{
			$resp = "VMS[$full]: $vm State: $pwrstate -- skipping"
			$full_vm_already_running++
			}
			if ($debug)
            {Write-Host $resp}
		}
		else
		{
		Write-Warning "Unable to find VM named $vm"
		}
	}
	#check the $startlist to see if its 0 size, if not start up contents
	if ($fullstartlist.count -gt 0)
	{
		if ($debug)
        {write-host "Adjusted startup list for FULL Operation has" $fullstartlist.count "items"}
		write-host ""
		write-host "Asking vCenter to startup" $fullstartlist.count "VMs"
		write-host "$full_vm_already_running VMs have already started"

		startvm_by_list_using_vcenter $fullstartlist
	}
	else 
	{
		#write-host "FULL Start: VM list to start was empty. (already running)"
		write-host "$full_vm_already_running of $fullvmscount VMs have already started"
	}
}





#makes lists of running vCenter vm, compares to list desired, only starts ones that are not already running
#has flag to speed up the start for FULL, no flag for OTM as they have some dependencies in start ordering
function start_OTM_vms()
{
	$OTM_vms=getOTM_vmlist
	if ($debug)
        {write-host $OTM_vms}
	#lets get the status of each match from vCenter, so we can save time and only start ones not started
	$vcentervms = getvcentervmlist
	write-host ""
	write-host "Starting" $OTM_vms.Count "VMs from the OTM Operation VM name list"
	if ($debug){write-host "OTM Start: Initial list has" $OTM_vms.Count "VM listed"}
	$otmvmscount=$OTM_vms.Count
	#write-host $OTM_vms.Count "VM listed for OTM"
	#create list
	$otmstartlist = New-Object 'System.collections.generic.list[System.object]'
	$otm_vm_already_running=0
	for ($otm=0; $otm -lt $OTM_vms.Count; ++$otm)
	{
		$vm=$OTM_vms[$otm]
		if ($vcentervms.Name -eq $vm)
		{
			$pwrstate=($vcentervms|where-object Name -eq $vm).PowerState
			$resp = "VMS[$otm]: $vm State: $pwrstate -- Unknown power state?"
			#Write-Host $resp
			if ($pwrstate -match "PoweredOff")
			{
			$resp = "VMS[$otm]: $vm State: $pwrstate -- Added to start list"
			$otmstartlist.add("$vm")
			}
			elseif ($pwrstate -match "PoweredOn")
			{
			$resp = "VMS[$otm]: $vm State: $pwrstate -- skipping"
			$otm_vm_already_running++
			}
			if ($debug)
            {Write-Host $resp}
		}
		else
		{
        Write-warning "Unable to find VM named $vm"
		}
	}
	#check the $startlist to see if its 0 size, if not start up contents
	if ($otmstartlist.count -gt 0)
	{
		if ($debug)
            {write-host "The adjusted startup list for OTM Operation has" $otmstartlist.count "items"}
			write-host ""
		write-host "Asking vCenter to startup" $otmstartlist.count "VMs"
		write-host "$otm_vm_already_running VMs have already started"
		
		startvm_by_list_using_vcenter $otmstartlist
	}
	else 
	{
		#write-host "OTM Start: VM list to start was emtpy. VM already running: $otm_vm_already_running
	write-host "$otm_vm_already_running of $otmvmscount VMs have already started"
	}
}

function stop_FULL_vms()
{
	$FULL_vms=getFULL_vmlist
	if ($debug)
            {write-host $FULL_vms}
	#lets get the status of each match from vCenter, so we can save time and only start ones not started
	$vcentervms = getvcentervmlist
    if ($debug)
    {
        write-host ""
	    write-host "There are" $FULL_vms.Count "VMs in the Full Operation VM name list"
    }
	$stopfullvmscount=$FULL_vms.Count
	
	#create list
	$fullstoplist = New-Object 'System.collections.generic.list[System.object]'
	#reverse ordering
	$full_vm_already_stopped=0
	
	for ($full=$FULL_vms.Count-1; $full -ge 0; --$full)
	{
		$vm=$FULL_vms[$full]
		if ($vcentervms.Name -eq $vm)
		{
			$pwrstate=($vcentervms|where-object Name -eq $vm).PowerState
			$resp = "VMS[$full]: $vm State: $pwrstate -- unknown power state?"
			#Write-Host $resp
			if ($pwrstate -match "PoweredOn")
			{
			$resp = "VMS[$full]: $vm State: $pwrstate -- Added to stop list"
			$fullstoplist.add("$vm")
			}
			elseif ($pwrstate -match "PoweredOff")
			{
			$resp = "VMS[$full]: $vm State: $pwrstate -- skipping"
			$full_vm_already_stopped++
			}
			if ($debug)
            {Write-Host $resp}
		}
		else
		{
        Write-Warning "Unable to find VM named $vm"
		}
	}
	#check the $startlist to see if its 0 size, if not start up contents
	if ($fullstoplist.count -gt 0)
	{
		if ($debug)
            {write-host "Adjusted stop list for Full Operation has" $fullstoplist.count "items"}
		write-host "Asking vCenter to shut down" $fullstoplist.count "VMs"
		write-host "$full_vm_already_stopped VMs have already shut down"

        #stop one by one (function used for both full and otm)
		if (!(stopvm_by_list_using_vcenter $fullstoplist))
        {
            Write-Warning "Error occurred while shutting down VMs using vCenter"
        }
	}
	else 
	{
		#write-host " --- FULL mode stop list was emtpy. There is nothing left to do"
        if ($debug)
        {write-host "Shutting down via vCenter task - $full_vm_already_stopped of $stopfullvmscount already shut down"}
	}
}

function stop_OTM_vms()
{
	$OTM_vms=getOTM_vmlist
	if ($debug)
    {write-host $OTM_vms}
	#lets get the status of each match from vCenter, so we can save time and only start ones not started
	$vcentervms = getvcentervmlist
	if ($debug)
    {
        write-host ""
	    write-host "There are" $OTM_vms.Count "VMs in the OTM Operation VM name list"
    }
	$otmvmstopcount=$OTM_vms.Count
	
	#create stop list
	$otmstoplist = New-Object 'System.collections.generic.list[System.object]'
	#reverse ordering
	$otm_vm_already_stopped=0
	
	for ($otm=$OTM_vms.Count-1; $otm -ge 0; --$otm)
	#for ($otm=0; $otm -lt $OTM_vms.Count; ++$otm)
	{
		$vm=$OTM_vms[$otm]
		if ($vcentervms.Name -eq $vm)
		{
			$pwrstate=($vcentervms|where-object Name -eq $vm).PowerState
			$resp = "VMS[$otm]: $vm State: $pwrstate -- unknown power state?"
			#Write-Host $resp
			if ($pwrstate -match "PoweredOn")
			{
			$resp = "VMS[$otm]: $vm State: $pwrstate -- Added to stop list"
			$otmstoplist.add("$vm")
			}
			elseif ($pwrstate -match "PoweredOff")
			{
			$resp = "VMS[$full]: $vm State: $pwrstate -- skipping"
			$otm_vm_already_stopped++
			}
			if ($debug)
            {Write-Host $resp}
		}
		else
		{
		Write-Warning "Unable to find VM named $vm"
		}
	}
	#check the $startlist to see if its 0 size, if not start up contents
	if ($otmstoplist.count -gt 0)
	{
		if ($debug)
        {write-host "Adjusted stop list for OTM Operation has" $otmstoplist.count "items"}
		write-host "Asking vCenter to shut down" $otmstoplist.count "VMs"
		write-host "$otm_vm_already_stopped VMs have already been shut down"

        #stop one by one (function used for both full and otm)
		if (!(stopvm_by_list_using_vcenter $otmstoplist))
        {
            Write-Warning "Error occurred while shutting down VMs using vCenter"
        }
	}
	else 
	{
		#write-host "OTM mode stop list was emtpy. Nothing left to do"
		if ($debug)
        {write-host "Shutting down via vCenter task - $otm_vm_already_stopped of $otmvmstopcount already shut down"}
	}
}



#this will take a list of vm to stop, and use vCenter 
function stopvm_by_list_using_vcenter($vmtostoplist)
{
	if (($null -eq $vmtostoplist) -or ($vmtostoplist.count -eq 0))
	{
		Write-Warning "The list of VMs is empty"
		return $false
	}
	else
	{
		#connect to vCenter if needed
		if (connect_to_vcenter)
		{
			if ($debug) {Write-Host "Connected to vCenter"}
			#we have a list, and are connected, stop the list

			for ($b = 0; $b -lt $vmtostoplist.count; $b++) 
			{
				$vm = $vmtostoplist[$b]
				if ($vm -ilike "vcsa")
				{
                    if ($debug)
                    {Write-Host "skipping $vm -- we are using it still to shutoff other virtual machines"}
				}
				else
				{
				Write-Host "Stopping $vm"
				shutdown-vmguest $vm -Confirm:$false -ErrorAction SilentlyContinue
				}
			}
			#return Get-VM -ErrorAction Continue 
		}
		else
		{
			Write-Warning "$($error[0])"
			Write-Warning "Unable to connect to vCenter"
   			Write-Host "Log into ESXi 1 and start it (if possible) then re-run this script"
			#Write-Host "The script will exit now"
   			#start-sleep 15
			#Read-Host -Prompt "Press any key to continue or CTRL+C to quit" | Out-Null
            forceuserconsent
			return $false
		}
	}
}

#this will take a list of vm to start, and use vCenter 
function startvm_by_list_using_vcenter($vmtostartlist)
{
	if (($null -eq $vmtostartlist) -or ($vmtostartlist.count -eq 0))
	{
		write-warning "ERROR: The list of VMs is empty"
		return $false
	}
	else
	{
		#connect to vCenter if needed
		if (connect_to_vcenter)
		{
			if ($debug)
            {Write-Host "Connected to vCenter"}
			#we have a list, and are connected, start them up

			for ($b = 0; $b -lt $vmtostartlist.count; $b++) 
			{
				$vm = $vmtostartlist[$b]
				Write-Host "Starting $vm"
				#add runasync flag (removed for now to test, seems to make odd output happen?)
				Start-VM -VM $vm -Confirm:$false -ErrorAction SilentlyContinue
			}
			#return Get-VM -ErrorAction Continue 
		}
		else
		{
			Write-Warning "Error: $($error[0])"
			Write-Warning "Unable to connect to vCenter"
   			Write-Host "Log into ESXi 1 and start it (if possible) then re-run this script"
      			Write-Host "The script will now exit"
			#start-sleep 15
			#Read-Host -Prompt "Press any key to continue or CTRL+C to quit" | Out-Null
            forceuserconsent
			exit
		}
	}
}

##gets list of all properties for vCenter known VM. useful for filtering through a list of vm actions based on powerstats
function getvcentervmlist()
{
    if ($debug) {Write-Host "Getting list of VM status from vCenter"}
	## we shouldnt need to get the creds by now, but just in case, we need to remake the object
    

        #$vis=Connect-VIServer -Server $vCenterIP -Credential $psCred -ErrorAction Continue
        if (connect_to_vcenter)
        {
            if ($debug)
            {Write-Host "Connected to vCenter"}
			#return get-vm -ErrorAction Continue | Where-Object {($_.powerstate -eq "PoweredOn") -and ($_.Name -inotlike "vCLS*")}
            #wow investigate
            return Get-VM -ErrorAction Continue 
        }
        else
        {
			Write-Host "Error: $($error[0])"
            Write-Warning "Unable to connect to vCenter"
	    Write-host "Log into ESXi 1 and start it (if possible) then re-run this script"
     	    Write-Host "The script will now exit"
			#start-sleep 15
			#Read-Host -Prompt "Press any key to continue or CTRL+C to quit" | Out-Null
            forceuserconsent
	    exit
        }
}

#we need a method to ensure were connected, or reconnect if not to be able to run commands easier
#having this in each function is nuisance
function connect_to_vcenter()
{
	if ($global:DefaultVIServer.Name -ne $vCenterIP)
	{
	#not connected, establish and return true, if fail, return false
	$msgPrompt="Please enter the vCenter Account"


    #user new method vCenter specific
    $psCred = getCredentials_vcenter $pfile $ufile $userName $vCenterIP
	if ($debug){Write-Host "Connecting to Host: $vCenterIP with User: $($psCred.UserName)"}
	if ($vctr=Connect-VIServer -Server $vCenterIP -Credential $psCred -ErrorAction Continue)
		{
		#write-host "session id = $vctr.SessionId"
		return $true
		#return $vctr.SessionId
		}
		else
		{
		Write-Warning "Unable to connect to vCenter"
  		Write-Host "Log into ESXi 1 and start it (if possible) then re-run this script"
    		Write-Host "The script will now exit"
		#start-sleep 15
		#Read-Host -Prompt "Press any key to continue or CTRL+C to quit" | Out-Null
        forceuserconsent
		exit
		}
	}
	else
	{
	if ($debug) {write-host "Still/Already connected to vCenter at "$global:DefaultVIServer}
	return $true
	}
}

function disconnect_from_vcenter()
{
	if ($global:DefaultVIServer.Name -eq $vCenterIP)
	{
	# connected, disconnect this, and return true if success, false if we cannot
	Disconnect-VIServer -Server $vCenterIP -Confirm:$false
		if ($global:DefaultVIServer.Name -eq $vCenterIP)
		{
			write-warning "Error: Unable to disconnect from vCenter"
			return $false
		}
		else
		{
		if ($debug){write-host "Disconnected from vCenter"}
		return $true
		}
	}
	else
	{
	if ($debug){write-host "Already disconnected from vCenter"}
	return $true
	}
}




######### This will pull in a list of virtual machine names to use for OTM mode
######### They are in a file, 1 line per entry, the file name is defined at the top of this script
function getOTM_vmlist() 
{
    #first check the file exists, or exit, we cant do any more without values, 
    #this check should happen at the start to avoid problems, or be created by the script with defaults before we get this far
    if (![System.IO.File]::Exists($OTM_listfile_path)) {Write-Warning "ERROR: Missing the file with the OTM Operation mode VM names. Please create txt file $OTM_listfile_path.  Inside it, you can add / remove / edit VM names for OTM Operation mode"}
    #read in contents to a list (maybe an array if needed to add more values like delay?)
	#filter blank lines, and special chars out
    $OTM_vms = Get-Content -Path $OTM_listfile_path | Where-Object {$_ -ne ""}
	$OTM_vms = ($OTM_vms -replace "^a-zA-Z0-9]")
    return $OTM_vms
}

function getFULL_vmlist() 
{
    #first check the file exists, or exit, we cant do any more without values, 
    #this check should happen at the start to avoid problems, or be created by the script with defaults before we get this far
    if (![System.IO.File]::Exists($FULL_operation_listfile_path)) {Write-Warning "ERROR: Missing the file with the FULL Operation mode VM names. Please create txt file $FULL_operation_listfile_path. Inside it you can add / remove / edit VM names for FULL Operation mode"}
    #read in contents to a list (maybe an array if needed to add more values like delay?)
	#filter blank lines, and special chars out
    $FULL_vms = Get-Content -Path $FULL_operation_listfile_path | Where-Object {$_ -ne ""}
	$FULL_vms = ($FULL_vms -replace "^a-zA-Z0-9]")
    return $FULL_vms
}

#exit


Write-Host "Setting the default values and initializing"

$null = Set-PowerCLIConfiguration -InvalidCertificateAction Ignore  -Confirm:$False -DisplayDeprecationWarnings:$False `
	-Scope Session -DefaultVIServerMode Single -WebOperationTimeoutSeconds $powercli_default_timeout -ErrorAction Continue 

class TrustAllCertsPolicy : System.Net.ICertificatePolicy {
    [bool] CheckValidationResult([System.Net.ServicePoint] $a, [System.Security.Cryptography.X509Certificates.X509Certificate] $b,
    [System.Net.WebRequest] $c,
    [int] $d) { return $True}
}
[System.Net.ServicePointManager]::CertificatePolicy = [TrustAllCertsPolicy]::new()


######################    initialize the 2 vm listfiles if not present   ##################
#create default vm list files if not there already
$OTM_VM_NAME_LIST = check_or_create_OTMlistfile
$FULL_VM_NAME_LIST = check_or_create_FULLOPlistfile


<#
#depricated
function switchmode_from_full_to_otm()
{
    #this assumes, its in full op mode already, all 3 esxi up, netapp, and vCenter.
    #connect vCenter, stop vm list for FULL, disconnect vCenter, tell them to power off esxi 2 and esxi 3
    connect_to_vcenter
    stop_FULL_vms
    disconnect_from_vcenter
    #stop esxi 2  and esxi 3 - 
    write-host "Shutting down ESXi 2"
    if (Test-Connection $ESXi2 -Quiet)
    {
        $host2power = shutdownESXiHost_single $ESXi2
        if ($host2power){}
    }
    else {Write-Host "ESXi 2 has already shut down"}
        
    write-host "Shutting down ESXi 3"
    if (Test-Connection $ESXi3 -Quiet)
    {
        $host3power = shutdownESXiHost_single $ESXi3
        if ($host3power){}
    }
    else {Write-Host "ESXi 3 has already shut down"}

    # Shut down NetApp if available
	shutdownNetAppTR_API
    #double check the netapp is ready for power off event.
    #since its probably off, the test is to the two service processors on it, they SHOULD be at the same state
    #a LOADER prompt on console
    $netAppReady_for_powerloss = verify_shutdownNetAppTR
    if($netAppReady_for_powerloss)
    {
        Write-Host "Completed switching to OTM Operation mode"
		Write-Host "Follow the steps in the TGS Lot G Power Procedure to power off the NetApp, ESXi 2 and 3 servers"
		#Start-Sleep 15
		#Read-Host -Prompt "Please press any key to continue or CTRL+C to quit" | Out-Null
        forceuserconsent
    }
    else {
        $netapperror = $true
		Write-Warning "ERROR: The NetApp is in an unknown state" 
		Write-Warning "You can view the logs at C:\temp\vrfylog1.txt and C:\temp\vrfylog2.txt" 
		#no need to sleep, its already in error state
		#Start-Sleep 15
		#Read-Host -Prompt "Press any key to continue or CTRL+C to quit" | Out-Null
        forceuserconsent
    }
}

function switchmode_from_otm_to_full()
{
    #this assumes, its in OTM mode already, only 1 esxi up, no netapp, and vCenter up.
    #get hardware up first, then auth on esxi2 and 3 in order to check they are fully up
    #connect vCenter, stop vm list for FULL, disconnect vCenter, tell them to power off esxi 2 and esxi 3
    Write-Host "Full Operation mode requires ESXi servers 1, 2, 3, and the NetApp to be running"
    Write-Host "Follow the steps in the TGS Lot G Power Procedure to power on the NetApp then the ESXi 2 and 3 servers"
    if(waitForGreenLotG_FULL)
    {    
    connect_to_vcenter
    start_FULL_vms
    disconnect_from_vcenter
    Write-Host "Completed switching modes from OTM to Full operation"
    }
}
#>

function start_java_vmmonitor($pathto_jar_file)
{
    #test path
    #Write-Host "path is " $pathto_jar_file
    if (Test-Path -Path $pathto_jar_file)
    {
        Start-Process -FilePath $pathto_jar_file
    }
    else {
        Write-Warning "Unable to find file $pathto_jar_file"
    }
}

function test_auth_on_all()
{
	write-host "Authentication failures can be caused"
	write-host "by the systems not being fully booted up before testing"
	Write-Host "Therefore the ESXi servers, VMs, and NetApp should"
	Write-Host "be given at least 10-15 minutes to boot up"
	Write-Host ""
	
    if (Test-Connection $vCenterIP -Quiet) {
      Write-Host "Checking vCenter credentials"  
      $vcenterauthtest=getCredentials_vcenter $pFile $uFile $userName $vCenterIP
	  if ($vcenterauthtest) {write-host "vCenter authentication successful"}
	  else {write-warning "ERROR: vCenter authentication failed"}
    }
    else {Write-Host "vCenter is not reachable"}
	Write-Host ""
    
    if (Test-Connection $ESXi1 -Quiet) {
        Write-Host "Checking ESXi 1 credentials"
        $esxi1authtest=getCredentials_esxi $pvFile $uvFile $userVName $ESXi1
		if ($esxi1authtest) {write-host "ESXi 1 authentication successful"}
		else {write-warning "ERROR: ESXi 1 authentication failed"}
    }
    else {Write-Host "ESXi 1 is not reachable"}
	Write-Host ""
    
    if (Test-Connection $ESXi2 -Quiet) {
        Write-Host "Checking ESXi 2 credentials"
        $esxi2authtest=getCredentials_esxi $pvFile $uvFile $userVName $ESXi2
		if ($esxi2authtest) {write-host "ESXi 2 authentication successful"}
		else {write-warning "ERROR: ESXi 2 authentication failed"}
    }
    else {Write-Host "ESXi 2 is not reachable"}
	Write-Host ""

    if (Test-Connection $ESXi3 -Quiet) {
        Write-Host "Checking ESXi 3 credentials"
        $esxi3authtest=getCredentials_esxi $pvFile $uvFile $userVName $ESXi3
		if ($esxi3authtest) {write-host "ESXi 3 authentication successful"}
		else {write-warning "ERROR: ESXi 3 authentication failed"}
    }
    else {Write-Host "ESXi 3 is not reachable"}
	Write-Host ""

    if (Test-Connection $NetAppIP -Quiet) {
        Write-Host "Checking NetApp credentials"
        $netappauthtest=getCredentials_netapp $pnFile $unFile $NetAppAdmin $NetAppIP
		if ($netappauthtest) {write-host "NetApp authentication successful"}
		else {write-warning "ERROR: NetApp authentication failed"}
    }
    else {Write-Host "NetApp is not reachable"}
	Write-Host ""

}

function Write-ColorOutput($ForegroundColor)
{
    #save current foreground color
    $fc = $host.UI.RawUI.ForegroundColor

    #set the new color
    $host.UI.RawUI.ForegroundColor = $ForegroundColor
    
    #output
    if ($args)
    {
        Write-Output $args
    }
    else {
        $input | Write-Output
    }

    #restore the original color
    $host.UI.RawUI.ForegroundColor = $fc
}
function Show-Menu
{
    param (
        [string]$Title = 'TGS Lot G Assistant'
    )
    Clear-Host
    Write-ColorOutput blue  "============ $Title version $version =============="
    Write-ColorOutput yellow "   Press '0' Validate saved credentials"
    Write-Host
    Write-ColorOutput blue "------------ System Status Monitor -------------------"
    Write-ColorOutput yellow "   Press '1' Start VM Monitor GUI"
    write-host
    Write-ColorOutput blue "------------ Starting Options ------------------------"
    Write-ColorOutput yellow "   Press '2' Start to OTM operation"
    Write-ColorOutput yellow "   Press '3' Start to Full operation"
    write-host
    Write-ColorOutput blue "------------ Shut Down Options -----------------------"
    Write-ColorOutput yellow "   Press '4' Shut Down (from OTM or Full operation)"
    write-host
    Write-ColorOutput blue "------------ Mode Switching Options ------------------"   
    Write-ColorOutput yellow "   Press '5' Switch from Full to OTM operation"
    Write-ColorOutput yellow "   Press '6' Switch from OTM to Full operation"

    Write-Host
    Write-ColorOutput yellow "   Press 'Q' to quit"
    Write-Host
}

####### Main Menu ###########
do
{
    Show-Menu -Title 'TGS Lot G Assistant'
    Write-Host -ForegroundColor Yellow "Note: If the script fails to connect to the ESXi servers, Netapp, or vCenter then make sure that the SysCon in use has the Management VLAN (200) enabled"
    $userinput = Read-Host "Please select an option"
    switch ($userinput)
    {
        '0' {
		#Validate saved credentials
  		Clear-Host
		test_auth_on_all
                #Read-Host -Prompt "Please press any key to continue or CTRL+C to quit" | Out-Null
                Write-Host -ForegroundColor Green "The authentication has been tested"
		Write-Host -ForegroundColor Green "The script has completed and will now return to the main menu"
		forceuserconsent
            }
        '1' {
                #Start VM Monitor GUI
		clear-host
		start_java_vmmonitor $pathto_jar_file
                #Read-Host -Prompt "Please press any key to continue or CTRL+C to quit" | Out-Null
                Write-Host -ForegroundColor Yellow "Note: The VMMonitor does not include all of the VMs and there are just 3 ESXi servers in the TGS Lot G"
		Write-Host -ForegroundColor Green "The VMMonitor has opened"
		Write-Host -ForegroundColor Green "The script has completed and will now return to the main menu"
		forceuserconsent
            }
        '2' {
                #Start to OTM operation
		Clear-Host
		Write-Host "The script will begin"
  		Write-Host -ForegroundColor Yellow "Note: You do not need to wait for the script"
    		Write-Host "Follow the steps in the TGS Lot G Power Procedure (to start to OTM Operation mode)"
		forceuserconsent
		Start-to-otm-operation
		write-host -ForegroundColor Green "The TGS Lot G is in OTM Operation mode"
    		write-Host -ForegroundColor Green "The script has completed and will now return to the main menu"	
      		forceuserconsent
            }
        '3' {               
		#Start to Full operation
  		Clear-Host
		Write-Host "The script will begin"
  		Write-Host -ForegroundColor Yellow "Note: You do not need to wait for the script"
    		Write-Host "Follow the steps in the TGS Lot G Power Procedure (to start to Full Operation mode)"
		forceuserconsent
    		Start-to-full-operation
    		write-host -ForegroundColor Green "The TGS Lot G is in Full Operation mode"
    		write-Host -ForegroundColor Green "The script has completed and will now return to the main menu"	
      		forceuserconsent
            }
        '4' {
                #Shut Down (from OTM or Full operation)
		Clear-Host
                Write-Host "The script will begin"
		Write-Host -ForegroundColor Red "Warning: You must wait for the script to complete before proceeding with the TGS Lot G Power Procedure" 
		forceuserconsent
		if (waitForGreenLotG_shutdown_from_OTM_or_FULL)
                {
			Write-Host -ForegroundColor Green "The TGS Lot G has been shut down"
     			Write-Host -ForegroundColor Green "Follow the steps in the TGS Lot G Power Procedure (to power off [from OTM or Full Operation mode])"
	  		Write-Host -ForegroundColor Green "The script has completed and will now return to the main menu"
			#no need to sleep, successful
			#Start-Sleep 15
			#Read-Host -Prompt "Please press any key to continue or CTRL+C to quit" | Out-Null
                	forceuserconsent
                }
                else {
                	Write-warning "The TGS Lot G did not shut down as expected"
			Write-Host "Resolve the issue with vCenter (on ESXi 1), the ESXi server(s), and/or the NetApp then re-run this script"
			Write-Host "The script will now exit"
     			#no need to sleep, already in error state
			#Start-Sleep 15
			#Read-Host -Prompt "Please press any key to continue or CTRL+C to quit" | Out-Null
                    	forceuserconsent
		    	exit
                }
            }
        '5' {
                #Switch from Full to OTM operation
		Clear-Host
		Write-Host "The script will begin"
                Write-Host -ForegroundColor Yellow "Note: You do not need to wait for the script"
    		Write-Host "Follow the steps in the TGS Lot G Power Procedure (to switch from Full to OTM Operation mode)"
		forceuserconsent
                if (isVCenterUp)
                {stop_FULL_vms}
                #
		Start-to-otm-operation
		write-host -ForegroundColor Green "The TGS Lot G is in OTM Operation mode"
    		write-Host -ForegroundColor Green "The script has completed and will now return to the main menu"	
      		forceuserconsent
            }
        '6' {
                #Switch from OTM to Full operation
		Clear-Host
		Write-Host "The script will begin"
  		Write-Host -ForegroundColor Yellow "Note: You do not need to wait for the script" 
    		Write-Host "Follow the steps in the TGS Lot G Power Procedure (to switch from OTM to Full Operation mode)"
		forceuserconsent
                Start-to-full-operation
		write-host -ForegroundColor Green "The TGS Lot G is in Full Operation mode"
    		write-Host -ForegroundColor Green "The script has completed and will now return to the main menu"	
      		forceuserconsent		
            }

        'q' {
                #Quit / Exit
		write-Host -ForegroundColor Green "The script will now exit"
		start-sleep 3
		exit
           }



    }
    #pause
}
until ($input -eq 'q')	

