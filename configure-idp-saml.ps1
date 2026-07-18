<#
.SYNOPSIS
    Configure Keycloak (Red Hat SSO) as a SAML Identity Provider for IBM CPFS 4.x cp-console.

.DESCRIPTION
    Step 1  - Login to OCP cluster
    Step 2  - Install Red Hat SSO (Keycloak) operator via OLM
    Step 3  - Wait for rhsso-operator pod Running
    Step 4  - Create Keycloak instance (CR) and wait for it to become Ready
    Step 5  - Create Keycloak Realm (cpfs-realm)
    Step 6  - Create SAML Client in the realm (CPFS as Service Provider)
    Step 7  - Create test users in the realm (saml-admin, saml-viewer)
    Step 8  - Create groups and assign users
    Step 9  - Fetch Keycloak SAML metadata XML via its endpoint
    Step 10 - Create CPFS IdpConfig CR with the SAML metadata
    Step 11 - Wait for IdpConfig to become Ready
    Step 12 - Map Keycloak groups to CPFS roles via UserManagement CR
    Step 13 - Print SSO login URL and verification steps

.PARAMETER ConsoleUrl
    OCP web console URL. API URL is derived automatically.
    e.g. https://console-openshift-console.apps.CLUSTER.cp.fyre.ibm.com

.PARAMETER ClusterUrl
    OCP API URL override. Derived from ConsoleUrl if omitted.

.PARAMETER Username
    OCP login username. Default: kubeadmin

.PARAMETER Password
    OCP login password.

.PARAMETER CpConsoleUrl
    cp-console route URL. Derived from ConsoleUrl if omitted.
    e.g. https://cp-console-ibm-common-services.apps.CLUSTER.cp.fyre.ibm.com

.PARAMETER Namespace
    CPFS namespace. Default: ibm-common-services

.PARAMETER RhssoNamespace
    Namespace for Red Hat SSO (Keycloak). Default: rhsso

.PARAMETER RealmName
    Keycloak realm name. Default: cpfs-realm

.PARAMETER IdpName
    Name for the CPFS IdpConfig CR. Default: keycloak-saml

.PARAMETER AdminUser
    Test admin user to create in Keycloak. Default: saml-admin

.PARAMETER AdminPassword
    Password for the test admin user. Default: Admin1234!

.PARAMETER ViewerUser
    Test viewer user to create in Keycloak. Default: saml-viewer

.PARAMETER ViewerPassword
    Password for the test viewer user. Default: Viewer1234!

.PARAMETER SkipKeycloak
    Skip Keycloak install (Steps 2-8). Use when Keycloak is already running.

.EXAMPLE
    .\configure-idp-saml.ps1 `
        -ConsoleUrl 'https://console-openshift-console.apps.mycluster.cp.fyre.ibm.com' `
        -Password   'kubeadmin-password'

.EXAMPLE
    # Keycloak already installed -- only configure CPFS IdpConfig
    .\configure-idp-saml.ps1 -ConsoleUrl '...' -Password '...' -SkipKeycloak

.LINK
    https://www.ibm.com/docs/en/cloud-paks/foundational-services/4.x?topic=configuring-saml-authentication
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConsoleUrl,

    [string]$ClusterUrl      = '',
    [string]$Username        = 'kubeadmin',

    [Parameter(Mandatory = $true)]
    [string]$Password,

    [string]$CpConsoleUrl    = '',
    [string]$Namespace       = 'ibm-common-services',
    [string]$RhssoNamespace  = 'rhsso',
    [string]$RealmName       = 'cpfs-realm',
    [string]$IdpName         = 'keycloak-saml',
    [string]$AdminUser       = 'saml-admin',
    [string]$AdminPassword   = 'Admin1234!',
    [string]$ViewerUser      = 'saml-viewer',
    [string]$ViewerPassword  = 'Viewer1234!',
    [switch]$SkipKeycloak
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Banner([string]$msg) {
    Write-Host ''
    Write-Host ('-' * 64) -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host ('-' * 64) -ForegroundColor Cyan
}
function Write-Step([string]$msg)  { Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-Pass([string]$msg)  { Write-Host "  [OK]  $msg" -ForegroundColor Green }
function Write-Warn([string]$msg)  { Write-Host "  [!!]  $msg" -ForegroundColor Yellow }
function Write-Info([string]$msg)  { Write-Host "        $msg" }

function Invoke-Oc([string[]]$Arguments) {
    & oc @Arguments
    if ($LASTEXITCODE -ne 0) { throw "oc $($Arguments -join ' ') exited $LASTEXITCODE" }
}

function Invoke-OcJson([string[]]$Arguments) {
    $out = & oc @Arguments
    if ($LASTEXITCODE -ne 0) { throw "oc $($Arguments -join ' ') exited $LASTEXITCODE" }
    if (-not $out) { return $null }
    return $out | ConvertFrom-Json
}

# Calls the Keycloak Admin REST API. Returns parsed JSON.
function Invoke-KeycloakApi {
    param(
        [string]$Method,
        [string]$Path,
        [string]$Token,
        [string]$Body = '',
        [string]$ContentType = 'application/json'
    )
    $uri = "$script:KeycloakBaseUrl/auth/admin$Path"
    $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/json' }
    $params = @{
        Uri                  = $uri
        Method               = $Method
        Headers              = $headers
        SkipCertificateCheck = $true
        TimeoutSec           = 30
        ErrorAction          = 'Stop'
    }
    if ($Body) {
        $params['Body']        = $Body
        $params['ContentType'] = $ContentType
    }
    try {
        $resp = Invoke-WebRequest @params
        if ($resp.Content) { return $resp.Content | ConvertFrom-Json }
        return $null
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        if ($status -eq 409) { return $null }   # already exists — treat as OK
        throw $_
    }
}

# Gets a Keycloak admin token using the master realm service account.
function Get-KeycloakToken([string]$KcAdminPassword) {
    $uri = "$script:KeycloakBaseUrl/auth/realms/master/protocol/openid-connect/token"
    $body = "client_id=admin-cli&username=admin&password=$([uri]::EscapeDataString($KcAdminPassword))&grant_type=password"
    $resp = Invoke-WebRequest -Uri $uri -Method POST -Body $body `
        -ContentType 'application/x-www-form-urlencoded' `
        -SkipCertificateCheck -TimeoutSec 30 -ErrorAction Stop
    return ($resp.Content | ConvertFrom-Json).access_token
}

# ---------------------------------------------------------------------------
# Derive URLs
# ---------------------------------------------------------------------------
if (-not $ClusterUrl) {
    if ($ConsoleUrl -match 'apps\.(.+)$') {
        $clusterDomain = $Matches[1].TrimEnd('/')
        $ClusterUrl    = "https://api.$clusterDomain`:6443"
    } else {
        throw "Cannot derive API URL from ConsoleUrl '$ConsoleUrl'. Supply -ClusterUrl explicitly."
    }
}

if (-not $CpConsoleUrl) {
    if ($ConsoleUrl -match 'apps\.(.+)$') {
        $CpConsoleUrl = "https://cp-console-$Namespace.apps.$($Matches[1].TrimEnd('/'))"
    }
}

# KeycloakBaseUrl is set after Keycloak route is discovered in Step 4
$script:KeycloakBaseUrl = ''

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '+--------------------------------------------------------------+' -ForegroundColor Cyan
Write-Host '|  CPFS SAML IDP -- Keycloak (Red Hat SSO) Configurator       |' -ForegroundColor Cyan
Write-Host '+--------------------------------------------------------------+' -ForegroundColor Cyan
Write-Info "Cluster       : $ClusterUrl"
Write-Info "cp-console    : $CpConsoleUrl"
Write-Info "CPFS namespace: $Namespace"
Write-Info "RHSSO ns      : $RhssoNamespace"
Write-Info "Realm         : $RealmName"
Write-Info "IdP name      : $IdpName"
Write-Info "Test users    : $AdminUser  /  $ViewerUser"

# ---------------------------------------------------------------------------
# STEP 1 - Login
# ---------------------------------------------------------------------------
Write-Banner 'STEP 1 -- Login to OCP cluster'
Invoke-Oc @('login', $ClusterUrl, '-u', $Username, '-p', $Password, '--insecure-skip-tls-verify=true')
Write-Pass "Logged in as: $(& oc whoami)"

# ===========================================================================
# KEYCLOAK INSTALL (Steps 2-8)
# ===========================================================================
if ($SkipKeycloak) {
    Write-Warn 'SkipKeycloak set -- skipping Keycloak install (Steps 2-8)'
} else {

    # -----------------------------------------------------------------------
    # STEP 2 - Install Red Hat SSO operator via OLM
    # -----------------------------------------------------------------------
    Write-Banner 'STEP 2 -- Install Red Hat SSO (Keycloak) operator'

    # Check if already installed
    $kcCsv = & oc get csv -n $RhssoNamespace -o json 2>$null | ConvertFrom-Json
    $existingKc = if ($kcCsv -and $kcCsv.items) {
        @($kcCsv.items | Where-Object { $_.metadata.name -like 'rhsso-operator.*' -and $_.status.phase -eq 'Succeeded' })
    } else { @() }

    if ($existingKc.Count -gt 0) {
        Write-Pass "Red Hat SSO operator already installed: $($existingKc[0].metadata.name)"
    } else {
        # Namespace
        & oc create namespace $RhssoNamespace --dry-run=client -o yaml | & oc apply -f -

        # OperatorGroup (watch own namespace only)
        @"
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhsso-operator-group
  namespace: $RhssoNamespace
spec:
  targetNamespaces:
  - $RhssoNamespace
"@ | & oc apply -f -
        if ($LASTEXITCODE -ne 0) { throw 'Failed to apply RHSSO OperatorGroup.' }

        # Subscription
        @"
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhsso-operator
  namespace: $RhssoNamespace
spec:
  channel: stable
  installPlanApproval: Automatic
  name: rhsso-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
"@ | & oc apply -f -
        if ($LASTEXITCODE -ne 0) { throw 'Failed to apply RHSSO Subscription.' }
        Write-Pass 'RHSSO Subscription applied'

        # -----------------------------------------------------------------------
        # STEP 3 - Wait for rhsso-operator pod Running
        # -----------------------------------------------------------------------
        Write-Step 'STEP 3 -- Wait for rhsso-operator pod Running (up to 5 min)'
        $deadline = (Get-Date).AddMinutes(5); $opReady = $false
        while ((Get-Date) -lt $deadline) {
            $raw = & oc get pods -n $RhssoNamespace -o json 2>$null
            if ($raw) {
                $running = @(($raw | ConvertFrom-Json).items | Where-Object {
                    $_.metadata.name -like 'rhsso-operator*' -and $_.status.phase -eq 'Running'
                }).Count
                if ($running -ge 1) { $opReady = $true; break }
            }
            Write-Info 'Waiting for rhsso-operator pod...'; Start-Sleep -Seconds 15
        }
        if (-not $opReady) {
            & oc get pods -n $RhssoNamespace
            throw 'rhsso-operator pod did not start in time.'
        }
        Write-Pass 'rhsso-operator pod is Running'
    }

    # -----------------------------------------------------------------------
    # STEP 4 - Create Keycloak instance and wait for Ready
    # -----------------------------------------------------------------------
    Write-Step 'STEP 4 -- Create Keycloak instance (CR)'

    # Check if a Keycloak instance already exists
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $kcExists = & oc get keycloak keycloak -n $RhssoNamespace -o name 2>$null
    $ErrorActionPreference = $prev

    if (-not $kcExists) {
        @"
apiVersion: keycloak.org/v1alpha1
kind: Keycloak
metadata:
  name: keycloak
  namespace: $RhssoNamespace
spec:
  instances: 1
  externalAccess:
    enabled: true
  postgresDeploymentSpec:
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
"@ | & oc apply -f -
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create Keycloak instance CR.' }
        Write-Pass 'Keycloak CR created'
    } else {
        Write-Pass 'Keycloak CR already exists'
    }

    Write-Info 'Waiting for Keycloak to become Ready (up to 10 min)...'
    $deadline = (Get-Date).AddMinutes(10); $kcReady = $false
    while ((Get-Date) -lt $deadline) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $kcRaw = & oc get keycloak keycloak -n $RhssoNamespace -o json 2>$null
        $ErrorActionPreference = $prev
        if ($kcRaw) {
            $kc = $kcRaw | ConvertFrom-Json
            $ready = ($kc.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' })
            if ($ready) { $kcReady = $true; break }
            $msg = ($kc.status.conditions | Where-Object { $_.type -eq 'Ready' } | Select-Object -First 1).message
            Write-Info "Keycloak status: $msg"
        } else {
            Write-Info 'Waiting for Keycloak CR...'
        }
        Start-Sleep -Seconds 20
    }
    if (-not $kcReady) {
        & oc get pods -n $RhssoNamespace
        throw 'Keycloak did not become Ready in time.'
    }
    Write-Pass 'Keycloak is Ready'

    # Discover Keycloak route
    $kcHost = (& oc get keycloak keycloak -n $RhssoNamespace -o jsonpath='{.status.externalURL}' 2>$null).Trim()
    if (-not $kcHost) {
        $kcHost = (& oc get route keycloak -n $RhssoNamespace -o jsonpath='{.spec.host}' 2>$null).Trim()
        $kcHost = "https://$kcHost"
    }
    $script:KeycloakBaseUrl = $kcHost.TrimEnd('/')
    Write-Pass "Keycloak URL: $script:KeycloakBaseUrl"

    # Get Keycloak admin credentials from the generated secret
    $kcSecret = Invoke-OcJson @('get', 'secret', 'credential-keycloak', '-n', $RhssoNamespace, '-o', 'json')
    $kcAdminUser = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($kcSecret.data.ADMIN_USERNAME))
    $kcAdminPass = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($kcSecret.data.ADMIN_PASSWORD))
    Write-Pass "Keycloak admin credentials retrieved from secret 'credential-keycloak'"

    # Get admin token
    $kcToken = Get-KeycloakToken -KcAdminPassword $kcAdminPass
    Write-Pass 'Keycloak admin token obtained'

    # -----------------------------------------------------------------------
    # STEP 5 - Create Keycloak Realm
    # -----------------------------------------------------------------------
    Write-Step "STEP 5 -- Create Keycloak Realm: $RealmName"

    # Check if realm already exists
    $realmCheck = & oc get keycloakrealm -n $RhssoNamespace -o json 2>$null | ConvertFrom-Json
    $realmExists = if ($realmCheck -and $realmCheck.items) {
        @($realmCheck.items | Where-Object { $_.spec.realm.realm -eq $RealmName }).Count -gt 0
    } else { $false }

    if (-not $realmExists) {
        @"
apiVersion: keycloak.org/v1alpha1
kind: KeycloakRealm
metadata:
  name: $RealmName
  namespace: $RhssoNamespace
  labels:
    app: sso
spec:
  realm:
    realm: $RealmName
    displayName: CPFS SSO Realm
    enabled: true
    sslRequired: external
    loginWithEmailAllowed: true
    duplicateEmailsAllowed: false
    resetPasswordAllowed: true
    editUsernameAllowed: false
    bruteForceProtected: true
  instanceSelector:
    matchLabels:
      app: keycloak
"@ | & oc apply -f -
        if ($LASTEXITCODE -ne 0) { throw "Failed to create KeycloakRealm '$RealmName'." }

        Write-Info "Waiting for realm '$RealmName' to become Ready (up to 5 min)..."
        $deadline = (Get-Date).AddMinutes(5); $realmReady = $false
        while ((Get-Date) -lt $deadline) {
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            $rlRaw = & oc get keycloakrealm $RealmName -n $RhssoNamespace -o json 2>$null
            $ErrorActionPreference = $prev
            if ($rlRaw) {
                $rl = $rlRaw | ConvertFrom-Json
                $ready = ($rl.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' })
                if ($ready) { $realmReady = $true; break }
            }
            Write-Info 'Waiting for realm...'; Start-Sleep -Seconds 10
        }
        if (-not $realmReady) { Write-Warn "Realm may still be provisioning -- continuing." }
        else { Write-Pass "Realm '$RealmName' is Ready" }
    } else {
        Write-Pass "Realm '$RealmName' already exists"
    }

    # -----------------------------------------------------------------------
    # STEP 6 - Create SAML Client in the realm (CPFS as SP)
    # -----------------------------------------------------------------------
    Write-Step 'STEP 6 -- Create SAML Client for CPFS (Service Provider)'

    # Derive CPFS SP URLs from CpConsoleUrl
    $spEntityId  = "$CpConsoleUrl/ibm/saml20/initiatesso"
    $acsUrl      = "$CpConsoleUrl/ibm/saml20/callback"
    $sloUrl      = "$CpConsoleUrl/ibm/saml20/slo"

    Write-Info "SP Entity ID : $spEntityId"
    Write-Info "ACS URL      : $acsUrl"
    Write-Info "SLO URL      : $sloUrl"

    # Refresh token before long operation
    $kcToken = Get-KeycloakToken -KcAdminPassword $kcAdminPass

    $clientBody = @{
        clientId                  = 'cpfs-sp'
        name                      = 'CPFS Service Provider'
        description               = 'IBM Cloud Pak Foundational Services cp-console SAML SP'
        protocol                  = 'saml'
        enabled                   = $true
        frontchannelLogout        = $true
        fullScopeAllowed          = $true
        redirectUris              = @("$CpConsoleUrl/*")
        attributes                = @{
            'saml.authnstatement'            = 'true'
            'saml.server.signature'          = 'true'
            'saml.server.signature.keyinfo.ext' = 'false'
            'saml.signing.certificate'       = ''
            'saml.force.post.binding'        = 'true'
            'saml.multivalued.roles'         = 'false'
            'saml.encrypt'                   = 'false'
            'saml.client.signature'          = 'false'
            'saml_force_name_id_format'      = 'false'
            'saml.assertion.signature'       = 'true'
            'saml_name_id_format'            = 'email'
            'saml_signature_canonicalization_method' = 'http://www.w3.org/2001/10/xml-exc-c14n#'
            'saml.assertion.lifespan'        = '300'
        }
        protocolMappers           = @(
            @{
                name           = 'email'
                protocol       = 'saml'
                protocolMapper = 'saml-user-property-mapper'
                config         = @{
                    'attribute.name'       = 'email'
                    'attribute.nameformat' = 'Basic'
                    'user.attribute'       = 'email'
                }
            },
            @{
                name           = 'firstName'
                protocol       = 'saml'
                protocolMapper = 'saml-user-property-mapper'
                config         = @{
                    'attribute.name'       = 'firstName'
                    'attribute.nameformat' = 'Basic'
                    'user.attribute'       = 'firstName'
                }
            },
            @{
                name           = 'lastName'
                protocol       = 'saml'
                protocolMapper = 'saml-user-property-mapper'
                config         = @{
                    'attribute.name'       = 'lastName'
                    'attribute.nameformat' = 'Basic'
                    'user.attribute'       = 'lastName'
                }
            },
            @{
                name           = 'groups'
                protocol       = 'saml'
                protocolMapper = 'saml-group-membership-mapper'
                config         = @{
                    'attribute.name'       = 'groups'
                    'attribute.nameformat' = 'Basic'
                    'single'               = 'false'
                    'full.path'            = 'false'
                }
            }
        )
    } | ConvertTo-Json -Depth 10

    $null = Invoke-KeycloakApi -Method POST -Path "/realms/$RealmName/clients" -Token $kcToken -Body $clientBody
    Write-Pass "SAML client 'cpfs-sp' created in realm '$RealmName'"

    # Set the rootUrl, baseUrl, and valid redirect URIs via GET + PUT (handles update if 409 on create)
    $kcToken = Get-KeycloakToken -KcAdminPassword $kcAdminPass
    $clients = Invoke-KeycloakApi -Method GET -Path "/realms/$RealmName/clients?clientId=cpfs-sp" -Token $kcToken
    if ($clients -and $clients.Count -gt 0) {
        $clientId = $clients[0].id
        # Add fine-grained redirect using client update
        $updateBody = $clients[0]
        $updateBody.rootUrl       = $CpConsoleUrl
        $updateBody.baseUrl       = '/ibm/saml20/initiatesso'
        $updateBody.adminUrl      = $CpConsoleUrl
        $updateBody | Add-Member -MemberType NoteProperty -Name 'redirectUris' -Value @("$CpConsoleUrl/*") -Force
        $null = Invoke-KeycloakApi -Method PUT -Path "/realms/$RealmName/clients/$clientId" `
            -Token $kcToken -Body ($updateBody | ConvertTo-Json -Depth 10)
        Write-Pass "SAML client rootUrl and redirectUris updated"
    }

    # -----------------------------------------------------------------------
    # STEP 7 - Create test users
    # -----------------------------------------------------------------------
    Write-Step 'STEP 7 -- Create test users in Keycloak realm'
    $kcToken = Get-KeycloakToken -KcAdminPassword $kcAdminPass

    foreach ($u in @(
        @{ username = $AdminUser;  email = "$AdminUser@cpfs.local";  firstName = 'SAML'; lastName = 'Admin';  pwd = $AdminPassword  },
        @{ username = $ViewerUser; email = "$ViewerUser@cpfs.local"; firstName = 'SAML'; lastName = 'Viewer'; pwd = $ViewerPassword }
    )) {
        $userBody = @{
            username    = $u.username
            email       = $u.email
            firstName   = $u.firstName
            lastName    = $u.lastName
            enabled     = $true
            credentials = @(@{
                type      = 'password'
                value     = $u.pwd
                temporary = $false
            })
        } | ConvertTo-Json -Depth 5

        $null = Invoke-KeycloakApi -Method POST -Path "/realms/$RealmName/users" -Token $kcToken -Body $userBody
        Write-Pass "User '$($u.username)' created (email: $($u.email))"
    }

    # -----------------------------------------------------------------------
    # STEP 8 - Create groups and assign users
    # -----------------------------------------------------------------------
    Write-Step 'STEP 8 -- Create groups and assign users'
    $kcToken = Get-KeycloakToken -KcAdminPassword $kcAdminPass

    foreach ($g in @('cpfs-admins', 'cpfs-viewers')) {
        $null = Invoke-KeycloakApi -Method POST -Path "/realms/$RealmName/groups" `
            -Token $kcToken -Body (@{ name = $g } | ConvertTo-Json)
        Write-Pass "Group '$g' created"
    }

    # Assign users to groups
    $kcToken = Get-KeycloakToken -KcAdminPassword $kcAdminPass
    $groups  = Invoke-KeycloakApi -Method GET -Path "/realms/$RealmName/groups" -Token $kcToken
    $users   = Invoke-KeycloakApi -Method GET -Path "/realms/$RealmName/users"  -Token $kcToken

    $adminGroupId  = ($groups | Where-Object { $_.name -eq 'cpfs-admins'  } | Select-Object -First 1).id
    $viewerGroupId = ($groups | Where-Object { $_.name -eq 'cpfs-viewers' } | Select-Object -First 1).id
    $adminUserId   = ($users  | Where-Object { $_.username -eq $AdminUser  } | Select-Object -First 1).id
    $viewerUserId  = ($users  | Where-Object { $_.username -eq $ViewerUser } | Select-Object -First 1).id

    $null = Invoke-KeycloakApi -Method PUT -Path "/realms/$RealmName/users/$adminUserId/groups/$adminGroupId"   -Token $kcToken
    $null = Invoke-KeycloakApi -Method PUT -Path "/realms/$RealmName/users/$viewerUserId/groups/$viewerGroupId" -Token $kcToken
    Write-Pass "$AdminUser  --> group 'cpfs-admins'"
    Write-Pass "$ViewerUser --> group 'cpfs-viewers'"

} # end if -not SkipKeycloak

# ===========================================================================
# CPFS SAML CONFIGURATION (Steps 9-13)
# ===========================================================================
Write-Banner 'CPFS SAML Configuration'

# If SkipKeycloak, we still need the Keycloak URL and admin password
if ($SkipKeycloak) {
    Write-Step 'Resolving Keycloak URL from existing route'
    $kcRouteHost = (& oc get route keycloak -n $RhssoNamespace -o jsonpath='{.spec.host}' 2>$null).Trim()
    if (-not $kcRouteHost) { throw "Could not find Keycloak route in namespace '$RhssoNamespace'. Ensure Keycloak is installed." }
    $script:KeycloakBaseUrl = "https://$kcRouteHost"
    Write-Pass "Keycloak URL: $script:KeycloakBaseUrl"

    $kcSecret  = Invoke-OcJson @('get', 'secret', 'credential-keycloak', '-n', $RhssoNamespace, '-o', 'json')
    $kcAdminPass = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($kcSecret.data.ADMIN_PASSWORD))
}

# -----------------------------------------------------------------------
# STEP 9 - Fetch Keycloak SAML metadata XML
# -----------------------------------------------------------------------
Write-Step "STEP 9 -- Fetch Keycloak SAML metadata XML for realm '$RealmName'"

$metadataUrl = "$script:KeycloakBaseUrl/auth/realms/$RealmName/protocol/saml/descriptor"
Write-Info "Metadata URL: $metadataUrl"

# Retry loop — metadata endpoint is available only after realm is provisioned
$deadline = (Get-Date).AddMinutes(3); $metadataXml = $null
while ((Get-Date) -lt $deadline) {
    try {
        $metadataXml = (Invoke-WebRequest -Uri $metadataUrl -SkipCertificateCheck -TimeoutSec 15 -UseBasicParsing).Content
        if ($metadataXml -match 'EntityDescriptor') { break }
    } catch {
        Write-Info "Metadata not ready yet, retrying..."
    }
    Start-Sleep -Seconds 10
}
if (-not ($metadataXml -match 'EntityDescriptor')) {
    throw "Could not retrieve SAML metadata from Keycloak. URL: $metadataUrl"
}
Write-Pass 'SAML metadata XML retrieved from Keycloak'

# Base64-encode the metadata for embedding in the CPFS CR
$metadataB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($metadataXml))

# -----------------------------------------------------------------------
# STEP 10 - Create CPFS IdpConfig CR
# -----------------------------------------------------------------------
Write-Step "STEP 10 -- Create CPFS IdpConfig CR: $IdpName"

# CPFS derives the SP entity ID from the cp-console route automatically;
# we set it explicitly to match what we registered in Keycloak.
$spEntityId = "$CpConsoleUrl/ibm/saml20/initiatesso"

@"
apiVersion: operator.ibm.com/v1alpha1
kind: IdpConfig
metadata:
  name: $IdpName
  namespace: $Namespace
spec:
  idpType: SAML
  idpConfig:
    enabled: true
    name: $IdpName
    protocol: SAML
    type: SAML
    idp_discovery: true
    saml:
      enabled:             true
      idpMetadata:         $metadataB64
      idpMetadataEncoding: base64
      entityId:            $spEntityId
      nameIdFormat:        email
      signRequest:         false
      responseIncludesSig: true
      mapIdpGroup:         true
      groupsAttribute:     groups
      userFilter:          ""
"@ | & oc apply -f -
if ($LASTEXITCODE -ne 0) { throw 'Failed to create IdpConfig CR.' }
Write-Pass "IdpConfig CR '$IdpName' applied"

# -----------------------------------------------------------------------
# STEP 11 - Wait for IdpConfig Ready
# -----------------------------------------------------------------------
Write-Step 'STEP 11 -- Wait for IdpConfig to become Ready (up to 5 min)'
$deadline = (Get-Date).AddMinutes(5); $idpReady = $false
while ((Get-Date) -lt $deadline) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $idpRaw = & oc get idpconfig $IdpName -n $Namespace -o json 2>$null
    $ErrorActionPreference = $prev
    if ($idpRaw) {
        $idp     = $idpRaw | ConvertFrom-Json
        $phase   = $idp.status.idpStatus
        $msg     = $idp.status.message
        Write-Info "IdpConfig status: $phase  $msg"
        if ($phase -match 'Enabled|Ready|Running') { $idpReady = $true; break }
    } else {
        Write-Info 'Waiting for IdpConfig status...'
    }
    Start-Sleep -Seconds 15
}
if (-not $idpReady) {
    Write-Warn 'IdpConfig may still be initialising -- continuing'
} else {
    Write-Pass "IdpConfig '$IdpName' is Ready"
}

# -----------------------------------------------------------------------
# STEP 12 - Map Keycloak groups to CPFS roles
# -----------------------------------------------------------------------
Write-Step 'STEP 12 -- Map Keycloak groups to CPFS roles'

# cpfs-admins  --> ClusterAdministrator
# cpfs-viewers --> Viewer
@"
apiVersion: user.openshift.io/v1
kind: Group
metadata:
  name: cpfs-admins
  annotations:
    icp.ibm.com/type: SAML
    icp.ibm.com/idp: $IdpName
users: []
---
apiVersion: user.openshift.io/v1
kind: Group
metadata:
  name: cpfs-viewers
  annotations:
    icp.ibm.com/type: SAML
    icp.ibm.com/idp: $IdpName
users: []
"@ | & oc apply -f -

# CPFS role binding via IAM team (RBAC via RoleBinding in ibm-common-services)
@"
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cpfs-saml-admins-binding
subjects:
- kind: Group
  name: cpfs-admins
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: icp:cloudpak:administrator
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cpfs-saml-viewers-binding
subjects:
- kind: Group
  name: cpfs-viewers
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: icp:cloudpak:viewer
  apiGroup: rbac.authorization.k8s.io
"@ | & oc apply -f -
if ($LASTEXITCODE -ne 0) { Write-Warn 'ClusterRoleBinding apply had warnings -- check manually' }
else { Write-Pass 'CPFS role bindings applied' }

Write-Pass "cpfs-admins  --> ClusterRole 'icp:cloudpak:administrator'"
Write-Pass "cpfs-viewers --> ClusterRole 'icp:cloudpak:viewer'"

# -----------------------------------------------------------------------
# STEP 13 - Print SSO login URL and verification steps
# -----------------------------------------------------------------------
Write-Banner 'STEP 13 -- SSO Login URLs and Verification'

$ssoInitUrl = "$CpConsoleUrl/ibm/saml20/initiatesso"
$kcLoginUrl = "$script:KeycloakBaseUrl/auth/realms/$RealmName/account"

Write-Host ''
Write-Host '  ╔══════════════════════════════════════════════════════════╗' -ForegroundColor Green
Write-Host '  ║  SAML SSO CONFIGURATION COMPLETE                        ║' -ForegroundColor Green
Write-Host '  ╚══════════════════════════════════════════════════════════╝' -ForegroundColor Green
Write-Host ''
Write-Host '  cp-console URL:' -ForegroundColor Cyan
Write-Host "    $CpConsoleUrl" -ForegroundColor White
Write-Host ''
Write-Host '  SSO Login URL (initiates SAML flow):' -ForegroundColor Cyan
Write-Host "    $ssoInitUrl" -ForegroundColor White
Write-Host ''
Write-Host '  Keycloak Admin Console:' -ForegroundColor Cyan
Write-Host "    $script:KeycloakBaseUrl/auth/admin" -ForegroundColor White
Write-Host ''
Write-Host '  Keycloak Realm Account Page:' -ForegroundColor Cyan
Write-Host "    $kcLoginUrl" -ForegroundColor White
Write-Host ''
Write-Host '  Test Users:' -ForegroundColor Cyan
Write-Host "    $AdminUser  / $AdminPassword  (group: cpfs-admins  -> ClusterAdministrator)" -ForegroundColor White
Write-Host "    $ViewerUser / $ViewerPassword (group: cpfs-viewers -> Viewer)" -ForegroundColor White
Write-Host ''
Write-Host '  Verification commands:' -ForegroundColor Cyan
Write-Host "    oc get idpconfig $IdpName -n $Namespace" -ForegroundColor White
Write-Host "    oc get idpconfig $IdpName -n $Namespace -o jsonpath='{.status}'" -ForegroundColor White
Write-Host "    oc get clusterrolebinding cpfs-saml-admins-binding" -ForegroundColor White
Write-Host ''
Write-Host '  To test login:' -ForegroundColor Cyan
Write-Host "    1. Open $CpConsoleUrl in browser" -ForegroundColor White
Write-Host "    2. Click 'Log in with $IdpName'" -ForegroundColor White
Write-Host "    3. Enter username: $AdminUser  password: $AdminPassword" -ForegroundColor White
Write-Host "    4. You should be redirected back to cp-console as a ClusterAdministrator" -ForegroundColor White
Write-Host ''

# ---------------------------------------------------------------------------
# Post-config verification
# ---------------------------------------------------------------------------
Write-Banner 'Post-Config Verification'

Write-Info '--- IdpConfig ---'
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& oc get idpconfig -n $Namespace 2>$null
$ErrorActionPreference = $prev

Write-Info '--- Keycloak instance ---'
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& oc get keycloak -n $RhssoNamespace 2>$null
$ErrorActionPreference = $prev

Write-Info '--- Keycloak realm ---'
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& oc get keycloakrealm -n $RhssoNamespace 2>$null
$ErrorActionPreference = $prev

Write-Info '--- CPFS SAML role bindings ---'
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& oc get clusterrolebinding cpfs-saml-admins-binding cpfs-saml-viewers-binding 2>$null
$ErrorActionPreference = $prev

Write-Info '--- platform-auth-service pod (should still be Running) ---'
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& oc get pods -n $Namespace -l app=platform-auth-service 2>$null
$ErrorActionPreference = $prev
