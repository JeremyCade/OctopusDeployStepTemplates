###############################################################################
# TLS 1.2
###############################################################################
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

###############################################################################
# Required Modules
###############################################################################
Write-Host "Checking for required modules."

$required_posh_acme_version = 3.12.0
$module_check = Get-Module -ListAvailable -Name Posh-Acme | Where-Object { $_.Version -ge $required_posh_acme_version }

if (-not ($module_check)) {
    Write-Host "Installing Posh-ACME."
    Install-Module -Name Posh-ACME -MinimumVersion 3.12.0 -Scope CurrentUser -Force
}

Import-Module Posh-ACME

###############################################################################
# Constants
###############################################################################
$LE_Route53_Certificate_Name = "Lets Encrypt - $($OctopusParameters["LE_Route53_CertificateDomain"])"
$LE_Route53_Fake_Issuer = "Fake LE Intermediate X1"
$LE_Route53_Issuer = "Let's Encrypt Authority X3"

###############################################################################
# Helpers
###############################################################################
function Get-WebRequestErrorBody {
    param (
        $RequestError
    )

    # Powershell < 6 you can read the Exception
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        if ($RequestError.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($RequestError.Exception.Response.GetResponseStream())
            $reader.BaseStream.Position = 0
            $reader.DiscardBufferedData()
            $response = $reader.ReadToEnd()

            return $response | ConvertFrom-Json
        }
    }
    else {
        return $RequestError.ErrorDetails.Message
    }
}

###############################################################################
# Functions
###############################################################################
function Get-LetsEncryptCertificate {
    Write-Debug "Entering: Get-LetsEncryptCertificate"

    if ($OctopusParameters["LE_Route53_Use_Staging"]) {
        Write-Host "Using Lets Encrypt Server: Staging"
        Set-PAServer LE_STAGE;
    }
    else {
        Write-Host "Using Lets Encrypt Server: Production"
        Set-PAServer LE_PROD;
    }

    # Clobber account if it exists.
    $le_account = Get-PAAccount
    if ($le_account) {
        Remove-PAAccount $le_account.Id -Force
    }

    $aws_secret_key = ConvertTo-SecureString -String $OctopusParameters["LE_Route53_AWSAccount.SecretKey"] -AsPlainText -Force
    $route53_params = @{
        R53AccessKey = $OctopusParameters["LE_Route53_AWSAccount.AccessKey"];
        R53SecretKey = $aws_secret_key
    }

    try {
        return New-PACertificate -Domain $OctopusParameters["LE_Route53_CertificateDomain"] -AcceptTOS -Contact $OctopusParameters["LE_Route53_ContactEmailAddress"] -DnsPlugin Route53 -PluginArgs $route53_params -PfxPass $OctopusParameters["LE_Route53_PfxPassword"] -Force
    }
    catch {
        Write-Host "Failed to Create Certificate. Error Message: $($_.Exception.Message). See Debug output for details."
        Write-Debug (Get-WebRequestErrorBody -RequestError $_)
        exit 1
    }
}

function Get-OctopusCertificates {
    Write-Debug "Entering: Get-OctopusCertificates"

    $octopus_uri = $OctopusParameters["Octopus.Web.ServerUri"]
    $octopus_space_id = $OctopusParameters["Octopus.Space.Id"]
    $octopus_headers = @{ "X-Octopus-ApiKey" = $OctopusParameters["LE_Route53_Octopus_APIKey"] }
    $octopus_certificates_uri = "$octopus_uri/api/$octopus_space_id/certificates?search=$($OctopusParameters["LE_Route53_CertificateDomain"])"

    try {
        # Get a list of certificates that match our domain search criteria.
        $certificates_search = Invoke-WebRequest -Uri $octopus_certificates_uri -Method Get -Headers $octopus_headers -UseBasicParsing -ErrorAction Stop | ConvertFrom-Json | Select-Object -ExpandProperty Items

        # We don't want to confuse Production and Staging Lets Encrypt Certificates.
        $issuer = $LE_Route53_Issuer
        if ($OctopusParameters["LE_Route53_Use_Staging"]) {
            $issuer = $LE_Route53_Fake_Issuer
        }

        return $certificates_search | Where-Object {
            $_.SubjectCommonName -eq $OctopusParameters["LE_Route53_CertificateDomain"] -and
            $_.IssuerCommonName -eq $issuer -and
            $null -eq $_.ReplacedBy -and
            $null -eq $_.Archived
        }
    }
    catch {
        Write-Host "Could not retrieve certificates from Octopus Deploy. Error: $($_.Exception.Message). See Debug output for details."
        Write-Debug (Get-WebRequestErrorBody -RequestError $_)
        exit 1
    }
}

function Publish-OctopusCertificate {
    param (
        [string] $JsonBody
    )

    Write-Debug "Entering: Publish-OctopusCertificate"

    if (-not ($JsonBody)) {
        Write-Host "Existing Certificate Id and a replace Certificate are required."
        exit 1
    }

    $octopus_uri = $OctopusParameters["Octopus.Web.ServerUri"]
    $octopus_space_id = $OctopusParameters["Octopus.Space.Id"]
    $octopus_headers = @{ "X-Octopus-ApiKey" = $OctopusParameters["LE_Route53_Octopus_APIKey"] }
    $octopus_certificates_uri = "$octopus_uri/api/$octopus_space_id/certificates"

    try {
        Invoke-WebRequest -Uri $octopus_certificates_uri -Method Post -Headers $octopus_headers -Body $JsonBody -UseBasicParsing
        Write-Host "Published $($OctopusParameters["LE_Route53_CertificateDomain"]) certificate to the Octopus Deploy Certificate Store."
    }
    catch {
        Write-Host "Failed to publish $($OctopusParameters["LE_Route53_CertificateDomain"]) certificate. Error: $($_.Exception.Message). See Debug output for details."
        Write-Debug (Get-WebRequestErrorBody -RequestError $_)
        exit 1
    }
}

function Update-OctopusCertificate {
    param (
        [string]$Certificate_Id,
        [string]$JsonBody
    )

    Write-Debug "Entering: Update-OctopusCertificate"

    if (-not ($Certificate_Id -and $JsonBody)) {
        Write-Host "Existing Certificate Id and a replace Certificate are required."
        exit 1
    }

    $octopus_uri = $OctopusParameters["Octopus.Web.ServerUri"]
    $octopus_space_id = $OctopusParameters["Octopus.Space.Id"]
    $octopus_headers = @{ "X-Octopus-ApiKey" = $OctopusParameters["LE_Route53_Octopus_APIKey"] }
    $octopus_certificates_uri = "$octopus_uri/api/$octopus_space_id/certificates/$Certificate_Id/replace"

    try {
        Invoke-WebRequest -Uri $octopus_certificates_uri -Method Post -Headers $octopus_headers -Body $JsonBody -UseBasicParsing
        Write-Host "Replaced $($OctopusParameters["LE_Route53_CertificateDomain"]) certificate in the Octopus Deploy Certificate Store."
    }
    catch {
        Write-Error "Failed to replace $($OctopusParameters["LE_Route53_CertificateDomain"]) certificate. Error: $($_.Exception.Message). See Debug output for details."
        Write-Debug (Get-WebRequestErrorBody -RequestError $_)
        exit 1
    }
}

function Get-NewCertificatePFXAsJson {
    param (
        $Certificate
    )

    Write-Debug "Entering: Get-NewCertificatePFXAsJson"

    if (-not ($Certificate)) {
        Write-Host "Certificate is required."
        Exit 1
    }

    [Byte[]]$certificate_buffer = [System.IO.File]::ReadAllBytes($Certificate.PfxFile)
    $certificate_base64 = [convert]::ToBase64String($certificate_buffer)

    $certificate_body = @{
        Name = "$LE_Route53_Certificate_Name";
        Notes            = "";
        CertificateData  = @{
            HasValue = $true;
            NewValue = $certificate_base64;
        };
        Password         = @{
            HasValue = $true;
            NewValue = $OctopusParameters["LE_Route53_PfxPassword"];
        };
    }

    return $certificate_body | ConvertTo-Json
}

function Get-ReplaceCertificatePFXAsJson {
    param (
        $Certificate
    )

    Write-Debug "Entering: Get-ReplaceCertificatePFXAsJson"

    if (-not ($Certificate)) {
        Write-Host "Certificate is required."
        Exit 1
    }

    [Byte[]]$certificate_buffer = [System.IO.File]::ReadAllBytes($Certificate.PfxFile)
    $certificate_base64 = [convert]::ToBase64String($certificate_buffer)

    $certificate_body = @{
        CertificateData = $certificate_base64;
        Password        = $OctopusParameters["LE_Route53_PfxPassword"];
    }

    return $certificate_body | ConvertTo-Json
}

###############################################################################
# DO THE THING | MAIN |
###############################################################################
Write-Debug "Do the Thing"

Write-Host "Checking for existing Lets Encrypt Certificates in the Octopus Deploy Certificates Store."
$certificates = Get-OctopusCertificates

# Check for PFX & PEM
if ($certificates) {

    # Handle weird behavior between Powershell 5 and Powershell 6+
    $certificate_count = 1
    if ($certificates.Count -ge 1) {
        $certificate_count = $certificates.Count
    }

    Write-Host "Found $certificate_count for $($OctopusParameters["LE_Route53_CertificateDomain"])."
    Write-Host "Checking to see if any expire within $($OctopusParameters["LE_Route53_ReplaceIfExpiresInDays"]) days."

    # Check Expiry Dates
    $expiring_certificates = $certificates | Where-Object { [DateTime]$_.NotAfter -lt (Get-Date).AddDays($OctopusParameters["LE_Route53_ReplaceIfExpiresInDays"]) }

    if ($expiring_certificates) {
        Write-Host "Found certificates that expire with $($OctopusParameters["LE_Route53_ReplaceIfExpiresInDays"]) days. Requesting new certificates for $($OctopusParameters["LE_Route53_CertificateDomain"]) from Lets Encrypt"
        $le_certificate = Get-LetsEncryptCertificate

        # PFX
        $existing_certificate = $certificates | Where-Object { $_.CertificateDataFormat -eq "Pkcs12" } | Select-Object -First 1
        $certificate_as_json = Get-ReplaceCertificatePFXAsJson -Certificate $le_certificate
        Update-OctopusCertificate -Certificate_Id $existing_certificate.Id -JsonBody $certificate_as_json
    }
    else {
        Write-Host "Nothing to do here..."
    }

    exit 0
}

# No existing Certificates - Lets get some new ones.
Write-Host "No existing certificates found for $($OctopusParameters["LE_Route53_CertificateDomain"])."
Write-Host "Request New Certificate for $($OctopusParameters["LE_Route53_CertificateDomain"]) from Lets Encrypt"

# New Certificate..
$le_certificate = Get-LetsEncryptCertificate

Write-Host "Publishing: LetsEncrypt - $($OctopusParameters["LE_Route53_CertificateDomain"]) (PFX)"
$certificate_as_json = Get-NewCertificatePFXAsJson -Certificate $le_certificate
Publish-OctopusCertificate -JsonBody $certificate_as_json

Write-Host "GREAT SUCCESS"
