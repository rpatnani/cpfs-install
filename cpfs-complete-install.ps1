<#
.SYNOPSIS
    Single-script end-to-end install of IBM CPFS 4.x with Keycloak SAML SSO on OCP/Fyre.
    Covers everything: NFS storage, cert-manager, CPFS operator, cp-console, Keycloak IdP, SAML config.

.DESCRIPTION
    Phase 1 - NFS StorageClass (Steps 1-8)
      1.  Login to OCP cluster
      2.  Check if StorageClass already exists
      3.  Configure NFS exports on master0 via oc debug node (no SSH)
      4.  Discover NFS server internal IP from OCP node object
      5.  Deploy nfs-subdir-external-provisioner (RBAC + StorageClass + Deployment)
      6.  Wait for provisioner pod Running
      7.  Smoke-test PVC bind/delete
      8.  Mark StorageClass as cluster default

    Phase 2 - IBM CPFS 4.x (Steps 9-17)
      9.  Install IBM cert-manager operator from ibm-cert-manager-catalog (required prereq)
      10. Wait for IBM cert-manager pods Ready
      11. Pre-flight checks
      12. Idempotency check (skip if CPFS already installed)
      13. Create ibm-operators namespace
      14. Create IBM entitlement-key pull secret
      15. Apply IBM Operator CatalogSource + wait for pod Ready
      16. Apply OperatorGroup + Subscription + wait for CSV Succeeded
      17. Apply CommonService CR + wait for phase Succeeded

    Phase 3 - cp-console / IAM Stack (Steps 18-21)
      18. Apply OperandRequest (IAM + CommonUI + PostgreSQL + Management Ingress)
      19. Wait for PostgreSQL cluster healthy
      20. Wait for all IAM pods Running
      21. Print cp-console URL + extract initial admin credentials

    Phase 4 - Keycloak SAML IDP (Steps 22-34)
      22. Install RHBK operator (rhbk-operator) via OLM from redhat-operators channel stable-v24
      23. Wait for rhbk-operator pod Running
      24. Create Keycloak instance CR (cs-keycloak, k8s.keycloak.org/v2alpha1) + wait for Ready
      25. Create Keycloak Realm (cpfs-realm)
      26. Create SAML Client in the realm (CPFS as Service Provider)
      27. Create test users in the realm (saml-admin, saml-viewer)
      28. Create groups and assign users (cpfs-admins, cpfs-viewers)
      29. Fetch Keycloak SAML metadata XML
      30. Create CPFS IdpConfig CR with the SAML metadata
      31. Wait for IdpConfig to become Ready
      32. Map Keycloak groups to CPFS roles (ClusterAdministrator, Viewer)
      33. Final summary banner with all URLs and credentials
      34. Post-install verification

.PARAMETER ConsoleUrl
    OCP web console URL. API URL is derived automatically.
    e.g. https://console-openshift-console.apps.CLUSTER.cp.fyre.ibm.com

.PARAMETER ClusterUrl
    OCP API URL override. Derived from ConsoleUrl if omitted.

.PARAMETER Username
    OCP login username. Default: kubeadmin

.PARAMETER Password
    OCP login password.

.PARAMETER EntitlementKey
    IBM Entitlement Key from myibm.ibm.com/products-services/containerlibrary

.PARAMETER NfsHost
    OCP node to host NFS exports. Default: master0.<cluster-domain>

.PARAMETER NfsDir
    NFS export directory. Default: /var/data/dynamic
    NOTE: Must be under /var on RHCOS (root is read-only composefs).

.PARAMETER NfsNamespace
    Namespace for the NFS provisioner. Default: managed-nfs-storage

.PARAMETER StorageClass
    StorageClass name to create. Default: managed-nfs-storage

.PARAMETER Namespace
    CPFS operator namespace. Default: ibm-operators

.PARAMETER Channel
    OLM subscription channel. Default: v4.19

.PARAMETER Size
    CommonService size: starterset|small|medium|large. Default: medium

.PARAMETER RhssoNamespace
    Namespace for RHBK Keycloak operator. Default: ibm-operators
    (On your cluster Keycloak runs in the same ibm-operators namespace as CPFS)

.PARAMETER RealmName
    Keycloak realm name. Default: cpfs-realm

.PARAMETER IdpName
    CPFS IdpConfig CR name. Default: keycloak-saml

.PARAMETER AdminUser
    Test admin username to create in Keycloak. Default: saml-admin

.PARAMETER AdminPassword
    Test admin password. Default: Admin1234!

.PARAMETER ViewerUser
    Test viewer username to create in Keycloak. Default: saml-viewer

.PARAMETER ViewerPassword
    Test viewer password. Default: Viewer1234!

.PARAMETER SkipStorage
    Skip Phase 1 (NFS). Use when a StorageClass already exists.

.PARAMETER SkipCertManager
    Skip cert-manager install. Use when already installed on the cluster.

.PARAMETER SkipPreflight
    Skip pre-flight checks (Step 11).

.PARAMETER SkipConsole
    Skip Phase 3 (cp-console / IAM). Installs CPFS operator only.

.PARAMETER SkipSaml
    Skip Phase 4 (Keycloak + SAML). Installs CPFS + cp-console only.

.PARAMETER SkipKeycloak
    Skip Keycloak install (Steps 22-28). Use when Keycloak is already running.
    Phase 4 still runs to configure CPFS IdpConfig.

.EXAMPLE
    # Full install — everything end-to-end
    .\cpfs-complete-install.ps1 `
        -ConsoleUrl     'https://console-openshift-console.apps.mycluster.cp.fyre.ibm.com' `
        -Password       'kubeadmin-password' `
        -EntitlementKey 'your-ibm-entitlement-key'

.EXAMPLE
    # NFS + CPFS + cp-console only (no SAML)
    .\cpfs-complete-install.ps1 -ConsoleUrl '...' -Password '...' -EntitlementKey '...' -SkipSaml

.EXAMPLE
    # SAML only — CPFS already installed, just add Keycloak IDP
    .\cpfs-complete-install.ps1 -ConsoleUrl '...' -Password '...' -EntitlementKey '...' `
        -SkipStorage -SkipCertManager -SkipConsole

.EXAMPLE
    # Re-run idempotent — safe to run again on an existing install
    .\cpfs-complete-install.ps1 -ConsoleUrl '...' -Password '...' -EntitlementKey '...'

.LINK
    https://www.ibm.com/docs/en/cloud-paks/foundational-services/4.x
    https://github.com/rpatnani/cpfs-install
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConsoleUrl,

    [string]$ClusterUrl      = '',
    [string]$Username        = 'kubeadmin',

    [Parameter(Mandatory = $true)]
    [string]$Password,

    [Parameter(Mandatory = $true)]
    [string]$EntitlementKey,

    # NFS
    [string]$NfsHost         = '',
    [string]$NfsDir          = '/var/data/dynamic',
    [string]$NfsNamespace    = 'managed-nfs-storage',
    [string]$StorageClass    = 'managed-nfs-storage',

    # CPFS
    [string]$Namespace       = 'ibm-operators',
    [string]$Channel         = 'v4.19',
    [string]$Size            = 'medium',

    # Keycloak / SAML
    [string]$RhssoNamespace  = 'ibm-operators',
    [string]$RealmName       = 'cpfs-realm',
    [string]$IdpName         = 'keycloak-saml',
    [string]$AdminUser       = 'saml-admin',
    [string]$AdminPassword   = 'Admin1234!',
    [string]$ViewerUser      = 'saml-viewer',
    [string]$ViewerPassword  = 'Viewer1234!',

    # Skip flags
    [switch]$SkipStorage,
    [switch]$SkipCertManager,
    [switch]$SkipPreflight,
    [switch]$SkipConsole,
    [switch]$SkipSaml,
    [switch]$SkipKeycloak
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# =============================================================================
# HELPERS
# =============================================================================
function Write-Banner([string]$msg) {
    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host ('=' * 64) -ForegroundColor Cyan
}
function Write-Phase([string]$msg) {
    Write-Host ''
    Write-Host ('+' + ('-' * 62) + '+') -ForegroundColor Magenta
    Write-Host "|  $($msg.PadRight(60))|" -ForegroundColor Magenta
    Write-Host ('+' + ('-' * 62) + '+') -ForegroundColor Magenta
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

# Runs a shell command on an OCP node via oc debug + nsenter (no SSH).
# RHCOS root (/) is a read-only composefs — nsenter gives a writable host fs.
function Invoke-OcNodeDebug([string]$NodeName, [string]$Command) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = & oc debug "node/$NodeName" -- nsenter -a -t 1 -- bash -c $Command 2>&1
        $rc  = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    $outStr = ($out -join "`n")
    if ($rc -ne 0 -and $outStr -notmatch 'NFS_CONFIGURED_OK') {
        $errors = $out | Where-Object { $_ -notmatch 'Starting pod|Removing debug pod' }
        throw "oc debug node/$NodeName failed (exit $rc).`nOutput: $($errors -join "`n")"
    }
    return $outStr
}

# Calls Keycloak Admin REST API.
function Invoke-KeycloakApi {
    param([string]$Method, [string]$Path, [string]$Token,
          [string]$Body = '', [string]$ContentType = 'application/json')
    $uri = "$script:KcBaseUrl/auth/admin$Path"
    $h   = @{ Authorization = "Bearer $Token"; Accept = 'application/json' }
    $p   = @{ Uri = $uri; Method = $Method; Headers = $h
              SkipCertificateCheck = $true; TimeoutSec = 30; ErrorAction = 'Stop' }
    if ($Body) { $p['Body'] = $Body; $p['ContentType'] = $ContentType }
    try {
        $r = Invoke-WebRequest @p
        if ($r.Content) { return $r.Content | ConvertFrom-Json }
        return $null
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 409) { return $null }
        throw $_
    }
}

# Gets a short-lived Keycloak admin access token.
function Get-KcToken([string]$KcPass) {
    $uri  = "$script:KcBaseUrl/auth/realms/master/protocol/openid-connect/token"
    $body = "client_id=admin-cli&username=admin&password=$([uri]::EscapeDataString($KcPass))&grant_type=password"
    $r    = Invoke-WebRequest -Uri $uri -Method POST -Body $body `
                -ContentType 'application/x-www-form-urlencoded' `
                -SkipCertificateCheck -TimeoutSec 30 -ErrorAction Stop
    return ($r.Content | ConvertFrom-Json).access_token
}

# =============================================================================
# DERIVE URLs
# =============================================================================
if (-not $ClusterUrl) {
    if ($ConsoleUrl -match 'apps\.(.+)$') {
        $clusterDomain = $Matches[1].TrimEnd('/')
        $ClusterUrl    = "https://api.$clusterDomain`:6443"
    } else {
        throw "Cannot derive API URL from ConsoleUrl. Supply -ClusterUrl explicitly."
    }
}

if (-not $NfsHost) {
    if ($ClusterUrl -match 'api\.(.+):\d+') {
        $NfsHost = "master0.$($Matches[1])"
    } else {
        throw "Cannot derive NFS node from ClusterUrl. Supply -NfsHost explicitly."
    }
}

$CpConsoleUrl = ''   # resolved after cp-console is deployed
if ($ConsoleUrl -match 'apps\.(.+)$') {
    $CpConsoleUrl = "https://cp-console-$Namespace.apps.$($Matches[1].TrimEnd('/'))"
}

$script:KcBaseUrl = ''   # resolved after Keycloak is deployed

# =============================================================================
# STARTUP BANNER
# =============================================================================
Write-Host ''
Write-Host '+================================================================+' -ForegroundColor Cyan
Write-Host '|  IBM CPFS 4.x -- COMPLETE INSTALL                             |' -ForegroundColor Cyan
Write-Host '|  NFS  >  CPFS  >  cp-console  >  Keycloak SAML SSO           |' -ForegroundColor Cyan
Write-Host '+================================================================+' -ForegroundColor Cyan
Write-Info "Cluster       : $ClusterUrl"
Write-Info "NFS node      : $NfsHost  ($NfsDir)"
Write-Info "StorageClass  : $StorageClass"
Write-Info "CPFS namespace: $Namespace  channel: $Channel  size: $Size"
Write-Info "RHBK ns       : $RhssoNamespace  realm: $RealmName  idp: $IdpName"
Write-Info "Test users    : $AdminUser / $ViewerUser"
Write-Info "Skip flags    : Storage=$SkipStorage  CertMgr=$SkipCertManager  Console=$SkipConsole  SAML=$SkipSaml  Keycloak=$SkipKeycloak"

# =============================================================================
# STEP 1 -- Login
# =============================================================================
Write-Banner 'STEP 1 -- Login to OCP cluster'
Invoke-Oc @('login', $ClusterUrl, '-u', $Username, '-p', $Password, '--insecure-skip-tls-verify=true')
Write-Pass "Logged in as: $(& oc whoami)"

# =============================================================================
# PHASE 1 -- NFS StorageClass
# =============================================================================
Write-Phase 'PHASE 1 -- NFS StorageClass'

if ($SkipStorage) {
    Write-Warn 'SkipStorage set -- skipping NFS phase'
} else {
    Write-Step 'STEP 2 -- Check existing StorageClasses'
    $existingSc = & oc get storageclass -o name 2>$null
    if ($existingSc) {
        Write-Warn "StorageClass(es) already exist: $existingSc -- skipping NFS setup"
        $SkipStorage = $true
    } else {
        Write-Info 'No StorageClass found -- proceeding with NFS setup.'
    }
}

if (-not $SkipStorage) {
    Write-Step 'STEP 3 -- Configure NFS exports on node via oc debug'
    $nfsCmd = "mkdir -p $NfsDir && " +
              "(grep -qF '$NfsDir' /etc/exports || " +
              "echo '$NfsDir 10.0.0.0/8(rw,sync,no_wdelay,no_root_squash,insecure)' >> /etc/exports) && " +
              "sed -i '/^\s*$/d' /etc/exports && sort -u /etc/exports -o /etc/exports && " +
              "exportfs -ra && " +
              "(systemctl restart nfs-server 2>/dev/null || systemctl restart nfs 2>/dev/null || true) && " +
              "echo NFS_CONFIGURED_OK"
    $result = Invoke-OcNodeDebug -NodeName $NfsHost -Command $nfsCmd
    if ($result -notmatch 'NFS_CONFIGURED_OK') { throw "NFS config failed: $result" }
    Write-Pass "NFS exports configured on $NfsHost ($NfsDir)"

    Write-Step 'STEP 4 -- Discover NFS server internal IP'
    $nfsIp = (& oc get node $NfsHost -o "jsonpath={.status.addresses[?(@.type=='InternalIP')].address}").Trim()
    if (-not ($nfsIp -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$')) {
        throw "Could not determine InternalIP of node $NfsHost. Got: '$nfsIp'"
    }
    Write-Pass "NFS server IP: $nfsIp"

    Write-Step 'STEP 5 -- Deploy NFS subdir external provisioner'
    & oc new-project $NfsNamespace 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Info "Namespace '$NfsNamespace' already exists" }

    $rbacYaml = (Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/kubernetes-sigs/nfs-subdir-external-provisioner/master/deploy/rbac.yaml' -UseBasicParsing).Content
    $rbacYaml = $rbacYaml -replace 'namespace:\s*\S+', "namespace: $NfsNamespace"
    $rbacYaml | & oc apply -f -
    if ($LASTEXITCODE -ne 0) { throw 'Failed to apply NFS RBAC.' }
    Invoke-Oc @('adm', 'policy', 'add-scc-to-user', 'hostmount-anyuid',
        "system:serviceaccount:${NfsNamespace}:nfs-client-provisioner")

    $classYaml = (Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/kubernetes-sigs/nfs-subdir-external-provisioner/master/deploy/class.yaml' -UseBasicParsing).Content
    $classYaml = $classYaml -replace '(?m)(^\s*name:\s*)managed-nfs-storage', "`${1}$StorageClass"
    $classYaml = $classYaml -replace '(?m)(^\s*storageclass\.kubernetes\.io/is-default-class:).*', '${1} "false"'
    $classYaml | & oc apply -f -
    if ($LASTEXITCODE -ne 0) { throw 'Failed to apply StorageClass.' }

    $deployYaml = (Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/kubernetes-sigs/nfs-subdir-external-provisioner/master/deploy/deployment.yaml' -UseBasicParsing).Content
    $deployYaml = $deployYaml -replace 'namespace:\s*\S+', "namespace: $NfsNamespace"
    $deployYaml = $deployYaml -replace '10\.3\.243\.101', $nfsIp
    $deployYaml = $deployYaml -replace '/ifs/kubernetes', $NfsDir
    $deployYaml | & oc apply -n $NfsNamespace -f -
    if ($LASTEXITCODE -ne 0) { throw 'Failed to apply NFS Deployment.' }
    Write-Pass 'NFS provisioner manifests applied'

    Write-Step 'STEP 6 -- Wait for NFS provisioner pod Running (up to 3 min)'
    $deadline = (Get-Date).AddMinutes(3); $ready = $false
    while ((Get-Date) -lt $deadline) {
        $raw = & oc get pods -n $NfsNamespace -o json 2>$null
        if ($raw -and @(($raw | ConvertFrom-Json).items | Where-Object { $_.status.phase -eq 'Running' }).Count -ge 1) {
            $ready = $true; break
        }
        Write-Info 'Waiting for NFS provisioner pod...'; Start-Sleep -Seconds 10
    }
    if (-not $ready) { & oc get pods -n $NfsNamespace; throw 'NFS pod did not start in time.' }
    Write-Pass 'NFS provisioner pod is Running'

    Write-Step 'STEP 7 -- Smoke-test PVC'
    @"
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: nfs-smoke-test
spec:
  storageClassName: $StorageClass
  accessModes: [ ReadWriteMany ]
  resources:
    requests:
      storage: 100Mi
"@ | & oc apply -n $NfsNamespace -f -
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create smoke-test PVC.' }
    $deadline = (Get-Date).AddMinutes(2); $bound = $false
    while ((Get-Date) -lt $deadline) {
        if ((& oc get pvc nfs-smoke-test -n $NfsNamespace -o jsonpath='{.status.phase}' 2>$null) -eq 'Bound') {
            $bound = $true; break
        }
        Write-Info 'Waiting for PVC to bind...'; Start-Sleep -Seconds 5
    }
    & oc delete pvc nfs-smoke-test -n $NfsNamespace --ignore-not-found=true 2>$null | Out-Null
    if (-not $bound) { throw "PVC did not bind -- NFS server ${nfsIp}:${NfsDir} may not be reachable." }
    Write-Pass 'PVC smoke test passed'

    Write-Step 'STEP 8 -- Set as default StorageClass'
    Invoke-Oc @('annotate', 'storageclass', $StorageClass,
        'storageclass.kubernetes.io/is-default-class=true', '--overwrite')
    Write-Pass "'$StorageClass' is now the default StorageClass"
}

# =============================================================================
# PHASE 2 -- IBM CPFS 4.x
# =============================================================================
Write-Phase 'PHASE 2 -- IBM Cloud Pak Foundational Services 4.x'

# STEP 9 - IBM cert-manager (ibm-cert-manager-operator from ibm-cert-manager-catalog)
# Your cluster uses IBM cert-manager v4.2 in namespace ibm-cert-manager, NOT Red Hat cert-manager.
if ($SkipCertManager) {
    Write-Warn 'SkipCertManager set -- skipping IBM cert-manager install'
} else {
    Write-Step 'STEP 9 -- IBM cert-manager operator (prereq for cp-console)'
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $ibmCmCsv = & oc get csv -n ibm-cert-manager -o jsonpath='{.items[0].metadata.name}' 2>$null
    $ErrorActionPreference = $prev
    if ($ibmCmCsv -like 'ibm-cert-manager-operator*') {
        Write-Pass "IBM cert-manager already installed: $ibmCmCsv"
    } else {
        # IBM cert-manager uses its own pinned CatalogSource
        @"
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-cert-manager-catalog
  namespace: openshift-marketplace
spec:
  displayName: ibm-cert-manager-4.2.18
  image: icr.io/cpopen/ibm-cert-manager-operator-catalog@sha256:latest
  publisher: IBM
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 45m
"@ | & oc apply -f -
        if ($LASTEXITCODE -ne 0) { throw 'Failed to apply ibm-cert-manager-catalog CatalogSource.' }

        & oc create namespace ibm-cert-manager --dry-run=client -o yaml | & oc apply -f -
        @"
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ibm-cert-manager-operator-group
  namespace: ibm-cert-manager
spec:
  targetNamespaces: [ ibm-cert-manager ]
"@ | & oc apply -f -
        @"
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-cert-manager-operator
  namespace: ibm-cert-manager
spec:
  channel: v4.2
  installPlanApproval: Automatic
  name: ibm-cert-manager-operator
  source: ibm-cert-manager-catalog
  sourceNamespace: openshift-marketplace
"@ | & oc apply -f -
        if ($LASTEXITCODE -ne 0) { throw 'Failed to apply IBM cert-manager Subscription.' }

        Write-Step 'STEP 10 -- Wait for IBM cert-manager pods Ready (up to 5 min)'
        $deadline = (Get-Date).AddMinutes(5); $cmReady = $false
        while ((Get-Date) -lt $deadline) {
            $raw = & oc get pods -n ibm-cert-manager -o json 2>$null
            if ($raw -and @(($raw | ConvertFrom-Json).items | Where-Object { $_.status.phase -eq 'Running' }).Count -ge 3) {
                $cmReady = $true; break
            }
            Write-Info 'Waiting for IBM cert-manager pods...'; Start-Sleep -Seconds 15
        }
        if (-not $cmReady) {
            & oc get pods -n ibm-cert-manager
            throw 'IBM cert-manager pods did not start in time.'
        }
        Write-Pass 'IBM cert-manager pods are Ready'
    }
}

# STEP 11 - Pre-flight checks
if ($SkipPreflight) {
    Write-Warn 'SkipPreflight set -- skipping pre-flight checks'
} else {
    Write-Step 'STEP 11 -- Pre-flight checks'
    & node "$PSScriptRoot/preflight-check.js"
    if ($LASTEXITCODE -ne 0) { throw 'Pre-flight checks failed -- fix issues above and re-run.' }
}

# STEP 12 - Idempotency check
Write-Step 'STEP 12 -- Check if CPFS is already installed'
$csvCheck    = & oc get csv -A -o json 2>$null | ConvertFrom-Json
$existingCsv = @($csvCheck.items | Where-Object {
    $_.metadata.name -like 'ibm-common-service-operator.v*' -and $_.status.phase -eq 'Succeeded'
})
if ($existingCsv.Count -gt 0) {
    Write-Pass "CPFS already installed: $($existingCsv[0].metadata.name)"
} else {
    Write-Info 'CPFS not installed -- proceeding.'

    Write-Step 'STEP 13 -- Ensure operator namespace'
    & oc create namespace $Namespace --dry-run=client -o yaml | & oc apply -f -
    if ($LASTEXITCODE -ne 0) { throw 'Failed to apply namespace.' }
    Write-Pass "Namespace '$Namespace' ready"

    Write-Step 'STEP 14 -- IBM Entitlement Key pull secret'
    & oc create secret docker-registry ibm-entitlement-key `
        --docker-server=cp.icr.io `
        --docker-username=cp `
        "--docker-password=$EntitlementKey" `
        '--docker-email=cpfs-install@cluster.local' `
        -n $Namespace `
        --dry-run=client -o yaml | & oc apply -f -
    if ($LASTEXITCODE -ne 0) { throw 'Failed to apply entitlement secret.' }
    Write-Pass "Secret 'ibm-entitlement-key' ready in '$Namespace'"

    Write-Step 'STEP 15 -- IBM Operator CatalogSource'
    @"
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-operator-catalog
  namespace: openshift-marketplace
spec:
  displayName: IBM Operator Catalog
  image: icr.io/cpopen/ibm-operator-catalog:latest
  publisher: IBM
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 45m
"@ | & oc apply -f -
    if ($LASTEXITCODE -ne 0) { throw 'Failed to apply CatalogSource.' }
    $deadline = (Get-Date).AddMinutes(5); $catReady = $false
    while ((Get-Date) -lt $deadline) {
        $raw = & oc get pods -n openshift-marketplace -l olm.catalogSource=ibm-operator-catalog -o json 2>$null
        if ($raw) {
            $cnt = @(($raw | ConvertFrom-Json).items | Where-Object {
                ($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' })
            }).Count
            if ($cnt -ge 1) { $catReady = $true; break }
        }
        Write-Info 'Waiting for catalog pod...'; Start-Sleep -Seconds 15
    }
    if (-not $catReady) { throw 'IBM Operator Catalog pod did not become Ready in time.' }
    Write-Pass 'IBM Operator Catalog pod is Ready'

    # IBM Zen operator — required for Zen UI stack on your cluster
    Write-Step 'STEP 15b -- IBM Zen operator Subscription'
    $zenCsv = & oc get csv -n $Namespace -o json 2>$null | ConvertFrom-Json
    $zenExists = if ($zenCsv -and $zenCsv.items) {
        @($zenCsv.items | Where-Object { $_.metadata.name -like 'ibm-zen-operator.*' -and $_.status.phase -eq 'Succeeded' }).Count -gt 0
    } else { $false }
    if (-not $zenExists) {
        @"
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-zen-operator
  namespace: $Namespace
spec:
  channel: v6.10
  installPlanApproval: Automatic
  name: ibm-zen-operator
  source: ibm-operator-catalog
  sourceNamespace: openshift-marketplace
"@ | & oc apply -f -
        if ($LASTEXITCODE -ne 0) { throw 'Failed to apply ibm-zen-operator Subscription.' }
        Write-Pass 'ibm-zen-operator Subscription applied'
    } else {
        Write-Pass 'ibm-zen-operator already installed'
    }

    # ibm-pg-operator — separate EDB PostgreSQL catalog (used by Keycloak on your cluster)
    Write-Step 'STEP 15c -- ibm-pg-operator CatalogSource + Subscription'
    $pgCsv = & oc get csv -n $Namespace -o json 2>$null | ConvertFrom-Json
    $pgExists = if ($pgCsv -and $pgCsv.items) {
        @($pgCsv.items | Where-Object { $_.metadata.name -like 'ibm-pg-operator.*' -and $_.status.phase -eq 'Succeeded' }).Count -gt 0
    } else { $false }
    if (-not $pgExists) {
        @"
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-pg-operator-catalog
  namespace: openshift-marketplace
spec:
  displayName: ibm-pg-operator-28.3.2
  image: icr.io/cpopen/ibm-pg-operator-catalog@sha256:latest
  publisher: IBM
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 45m
"@ | & oc apply -f -
        if ($LASTEXITCODE -ne 0) { throw 'Failed to apply ibm-pg-operator-catalog CatalogSource.' }
        @"
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-pg-operator
  namespace: $Namespace
spec:
  channel: v28
  installPlanApproval: Automatic
  name: ibm-pg-operator
  source: ibm-pg-operator-catalog
  sourceNamespace: openshift-marketplace
"@ | & oc apply -f -
        if ($LASTEXITCODE -ne 0) { throw 'Failed to apply ibm-pg-operator Subscription.' }
        Write-Pass 'ibm-pg-operator Subscription applied'
    } else {
        Write-Pass 'ibm-pg-operator already installed'
    }

    Write-Step 'STEP 16 -- OperatorGroup + Subscription'
    @"
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ibm-operators-operatorgroup
  namespace: $Namespace
spec:
  targetNamespaces: [ $Namespace ]
"@ | & oc apply -f -
    if ($LASTEXITCODE -ne 0) { throw 'Failed to apply OperatorGroup.' }

    @"
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-common-service-operator
  namespace: $Namespace
spec:
  channel: $Channel
  installPlanApproval: Automatic
  name: ibm-common-service-operator
  source: ibm-operator-catalog
  sourceNamespace: openshift-marketplace
"@ | & oc apply -f -
    if ($LASTEXITCODE -ne 0) { throw 'Failed to apply Subscription.' }
    Write-Pass "Subscription created on channel '$Channel'"

    $deadline = (Get-Date).AddMinutes(10); $csv = $null
    while ((Get-Date) -lt $deadline) {
        $list = Invoke-OcJson @('get', 'csv', '-n', $Namespace, '-o', 'json')
        $csv  = @($list.items | Where-Object { $_.metadata.name -like 'ibm-common-service-operator.v*' }) | Select-Object -First 1
        if ($csv) {
            Write-Info "CSV: $($csv.metadata.name)  phase=$($csv.status.phase)"
            if ($csv.status.phase -eq 'Succeeded') { break }
        } else { Write-Info 'Waiting for CSV...' }
        Start-Sleep -Seconds 20
    }
    if (-not $csv)                          { throw 'Timed out -- CSV never appeared.' }
    if ($csv.status.phase -ne 'Succeeded')  { & oc get installplan -n $Namespace; throw 'CSV did not reach Succeeded.' }
    Write-Pass "CSV '$($csv.metadata.name)' Succeeded"

    Write-Step 'STEP 17 -- CommonService CR'
    @"
apiVersion: operator.ibm.com/v3
kind: CommonService
metadata:
  name: common-service
  namespace: $Namespace
spec:
  license:
    accept: true
  operatorNamespace: $Namespace
  servicesNamespace: $Namespace
  size: $Size
  services:
  - name: ibm-iam-operator
    spec: {}
  - name: ibm-licensing-operator
    spec: {}
  - name: ibm-cert-manager-operator
    spec: {}
  - name: ibm-zen-operator
    spec: {}
"@ | & oc apply -f -
    if ($LASTEXITCODE -ne 0) { throw 'Failed to apply CommonService CR.' }
    $deadline = (Get-Date).AddMinutes(20); $csPhase = ''
    while ((Get-Date) -lt $deadline) {
        $csPhase = (& oc get commonservice common-service -n $Namespace -o jsonpath='{.status.phase}' 2>$null)
        Write-Info "CommonService phase: $csPhase"
        if ($csPhase -eq 'Succeeded') { break }
        Start-Sleep -Seconds 30
    }
    if ($csPhase -ne 'Succeeded') {
        Write-Warn "CommonService did not reach Succeeded in 20 min -- continuing"
        & oc logs -n $Namespace -l 'app.kubernetes.io/name=operand-deployment-lifecycle-manager' --tail=20 2>$null
    } else { Write-Pass 'CommonService phase = Succeeded' }
}

# =============================================================================
# PHASE 3 -- cp-console / IAM Stack
# =============================================================================
Write-Phase 'PHASE 3 -- cp-console (IAM Stack)'

if ($SkipConsole) {
    Write-Warn 'SkipConsole set -- skipping cp-console / IAM deployment'
} else {
    Write-Step 'STEP 18 -- Apply OperandRequest for IAM + cp-console stack'
    @"
apiVersion: operator.ibm.com/v1alpha1
kind: OperandRequest
metadata:
  name: common-service
  namespace: $Namespace
spec:
  requests:
  - registry: common-service
    registryNamespace: $Namespace
    operands:
    - name: ibm-im-operator
    - name: ibm-im-mongodb-operator
    - name: ibm-idp-config-ui-operator
    - name: ibm-management-ingress-operator
    - name: ibm-ingress-nginx-operator
    - name: ibm-licensing-operator
    - name: ibm-cert-manager-operator
    - name: common-service-postgresql
"@ | & oc apply -f -
    if ($LASTEXITCODE -ne 0) { throw 'Failed to apply OperandRequest.' }
    Write-Pass 'OperandRequest applied -- ODLM is deploying IAM stack'

    Write-Step 'STEP 19 -- Wait for PostgreSQL cluster healthy (up to 10 min)'
    $deadline = (Get-Date).AddMinutes(10); $pgReady = $false
    while ((Get-Date) -lt $deadline) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $pgRaw = & oc get cluster common-service-db -n $Namespace -o json 2>$null
        $ErrorActionPreference = $prev
        if ($pgRaw) {
            $pgPhase = ($pgRaw | ConvertFrom-Json).status.phase
            Write-Info "PostgreSQL phase: $pgPhase"
            if ($pgPhase -match 'healthy') { $pgReady = $true; break }
            if ($pgPhase -match 'Unable to create') {
                & oc annotate cluster common-service-db -n $Namespace "reconcile=$(Get-Date -Format 'yyyyMMddHHmmss')" --overwrite 2>$null | Out-Null
            }
        } else { Write-Info 'Waiting for PostgreSQL cluster CR...' }
        Start-Sleep -Seconds 20
    }
    if (-not $pgReady) {
        Write-Warn 'PostgreSQL not yet healthy -- install may still converge'
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & oc get cluster -n $Namespace 2>$null
        $ErrorActionPreference = $prev
    } else { Write-Pass 'PostgreSQL cluster is healthy' }

    Write-Step 'STEP 20 -- Wait for IAM pods Running (up to 15 min)'
    $iamPods = @('platform-auth-service','platform-identity-management','platform-identity-provider','common-web-ui')
    $deadline = (Get-Date).AddMinutes(15); $iamReady = $false
    while ((Get-Date) -lt $deadline) {
        $raw = & oc get pods -n $Namespace -o json 2>$null
        if ($raw) {
            $pods = ($raw | ConvertFrom-Json).items
            $readyCount = ($iamPods | Where-Object {
                $name = $_
                ($pods | Where-Object { $_.metadata.name -like "$name*" -and $_.status.phase -eq 'Running' }).Count -ge 1
            }).Count
            Write-Info "IAM pods Running: $readyCount / $($iamPods.Count)"
            if ($readyCount -eq $iamPods.Count) { $iamReady = $true; break }
        }
        Start-Sleep -Seconds 30
    }
    if (-not $iamReady) {
        Write-Warn 'Not all IAM pods Running yet -- install may still converge'
        & oc get pods -n $Namespace 2>$null
    } else { Write-Pass 'All IAM pods are Running' }

    Write-Step 'STEP 21 -- cp-console URL and initial credentials'
    $cpRoute = & oc get route cp-console -n $Namespace -o jsonpath='{.spec.host}' 2>$null
    if ($cpRoute) {
        $CpConsoleUrl = "https://$cpRoute"
        Write-Pass "cp-console URL: $CpConsoleUrl"
    } else {
        Write-Warn 'cp-console route not yet available -- using derived URL'
    }
    Write-Info '--- Initial IAM admin credentials ---'
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $credSecret = & oc get secret platform-auth-idp-credentials -n $Namespace -o name 2>$null
    $ErrorActionPreference = $prev
    if ($credSecret) {
        & oc extract secret/platform-auth-idp-credentials -n $Namespace --to=- 2>$null
    } else {
        Write-Warn "platform-auth-idp-credentials not yet present -- retry:"
        Write-Warn "  oc extract secret/platform-auth-idp-credentials -n $Namespace --to=-"
    }
}

# =============================================================================
# PHASE 4 -- Keycloak SAML IDP
# =============================================================================
Write-Phase 'PHASE 4 -- Keycloak SAML Identity Provider'

if ($SkipSaml) {
    Write-Warn 'SkipSaml set -- skipping Phase 4 entirely'
} else {

    if ($SkipKeycloak) {
        Write-Warn 'SkipKeycloak set -- skipping Keycloak install (Steps 22-28)'
    } else {

        # STEP 22 - Install RHBK operator (Red Hat Build of Keycloak v24)
        # Your cluster uses rhbk-operator v24 from redhat-operators channel stable-v24
        # NOT the old rhsso-operator
        Write-Step 'STEP 22 -- Install RHBK operator (rhbk-operator, stable-v24)'
        $kcCsv = & oc get csv -n $RhssoNamespace -o json 2>$null | ConvertFrom-Json
        $existingKc = if ($kcCsv -and $kcCsv.items) {
            @($kcCsv.items | Where-Object { $_.metadata.name -like 'rhbk-operator.*' -and $_.status.phase -eq 'Succeeded' })
        } else { @() }

        if ($existingKc.Count -gt 0) {
            Write-Pass "RHBK operator already installed: $($existingKc[0].metadata.name)"
        } else {
            & oc create namespace $RhssoNamespace --dry-run=client -o yaml | & oc apply -f -
            # Only create OperatorGroup if namespace is dedicated; ibm-operators already has one
            $ogExists = & oc get operatorgroup -n $RhssoNamespace -o name 2>$null
            if (-not $ogExists) {
                @"
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhbk-operator-group
  namespace: $RhssoNamespace
spec:
  targetNamespaces: [ $RhssoNamespace ]
"@ | & oc apply -f -
            }
            @"
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhbk-operator
  namespace: $RhssoNamespace
spec:
  channel: stable-v24
  installPlanApproval: Automatic
  name: rhbk-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
"@ | & oc apply -f -
            if ($LASTEXITCODE -ne 0) { throw 'Failed to apply RHBK Subscription.' }
            Write-Pass 'RHBK Subscription applied'

            # STEP 23 - Wait for rhbk-operator pod
            Write-Step 'STEP 23 -- Wait for rhbk-operator pod Running (up to 5 min)'
            $deadline = (Get-Date).AddMinutes(5); $opReady = $false
            while ((Get-Date) -lt $deadline) {
                $raw = & oc get pods -n $RhssoNamespace -o json 2>$null
                if ($raw -and @(($raw | ConvertFrom-Json).items | Where-Object {
                    $_.metadata.name -like 'rhbk-operator*' -and $_.status.phase -eq 'Running'
                }).Count -ge 1) { $opReady = $true; break }
                Write-Info 'Waiting for rhbk-operator pod...'; Start-Sleep -Seconds 15
            }
            if (-not $opReady) { & oc get pods -n $RhssoNamespace; throw 'rhbk-operator pod did not start in time.' }
            Write-Pass 'rhbk-operator pod is Running'
        }

        # STEP 24 - Create Keycloak instance (RHBK API k8s.keycloak.org/v2alpha1, name cs-keycloak)
        # Your cluster uses cs-keycloak with EDB PostgreSQL backend (keycloak-edb-cluster)
        Write-Step 'STEP 24 -- Create Keycloak instance CR (cs-keycloak) + wait for Ready'
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $kcExists = & oc get keycloak cs-keycloak -n $RhssoNamespace -o name 2>$null
        $ErrorActionPreference = $prev
        if (-not $kcExists) {
            @"
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: cs-keycloak
  namespace: $RhssoNamespace
spec:
  instances: 2
  db:
    vendor: postgres
    host: keycloak-edb-cluster-rw
    usernameSecret:
      name: keycloak-edb-cluster-app
      key: username
    passwordSecret:
      name: keycloak-edb-cluster-app
      key: password
  http:
    tlsSecret: cs-keycloak-tls-secret
  hostname:
    hostname: keycloak-$RhssoNamespace.apps.$clusterDomain
  ingress:
    enabled: false
  proxy:
    headers: xforwarded
  features:
    enabled:
    - token-exchange
    - admin-fine-grained-authz
  resources:
    requests:
      cpu: 1000m
      memory: 1Gi
    limits:
      cpu: 1000m
      memory: 1Gi
"@ | & oc apply -f -
            if ($LASTEXITCODE -ne 0) { throw 'Failed to create cs-keycloak instance CR.' }
            Write-Pass 'cs-keycloak CR created'
        } else {
            Write-Pass 'cs-keycloak CR already exists'
        }

        $deadline = (Get-Date).AddMinutes(10); $kcReady = $false
        while ((Get-Date) -lt $deadline) {
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            $kcRaw = & oc get keycloak cs-keycloak -n $RhssoNamespace -o json 2>$null
            $ErrorActionPreference = $prev
            if ($kcRaw) {
                $kc    = $kcRaw | ConvertFrom-Json
                $ready = ($kc.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' })
                if ($ready) { $kcReady = $true; break }
                $msg   = ($kc.status.conditions | Where-Object { $_.type -eq 'Ready' } | Select-Object -First 1).message
                Write-Info "cs-keycloak: $msg"
            } else { Write-Info 'Waiting for cs-keycloak CR...' }
            Start-Sleep -Seconds 20
        }
        if (-not $kcReady) { & oc get pods -n $RhssoNamespace; throw 'cs-keycloak did not become Ready in time.' }
        Write-Pass 'cs-keycloak is Ready'

        # RHBK route is created directly (not via externalURL field)
        $kcRouteHost = (& oc get route keycloak -n $RhssoNamespace -o jsonpath='{.spec.host}' 2>$null).Trim()
        $script:KcBaseUrl = "https://$kcRouteHost"
        Write-Pass "Keycloak URL: $script:KcBaseUrl"

        # RHBK stores initial admin credentials in secret cs-keycloak-initial-admin
        # (NOT credential-keycloak which was the old rhsso pattern)
        $kcSec = Invoke-OcJson @('get', 'secret', 'cs-keycloak-initial-admin', '-n', $RhssoNamespace, '-o', 'json')
        $kcAdminUser = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($kcSec.data.username))
        $kcAdminPass = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($kcSec.data.password))
        Write-Pass "Keycloak admin credentials retrieved from secret 'cs-keycloak-initial-admin' (user: $kcAdminUser)"
        $kcToken = Get-KcToken -KcPass $kcAdminPass
        Write-Pass 'Keycloak admin token obtained'

        # STEP 25 - Create realm
        Write-Step "STEP 25 -- Create Keycloak Realm: $RealmName"
        $realmCheck  = & oc get keycloakrealm -n $RhssoNamespace -o json 2>$null | ConvertFrom-Json
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
            $deadline = (Get-Date).AddMinutes(5); $realmReady = $false
            while ((Get-Date) -lt $deadline) {
                $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                $rlRaw = & oc get keycloakrealm $RealmName -n $RhssoNamespace -o json 2>$null
                $ErrorActionPreference = $prev
                if ($rlRaw -and ($rlRaw | ConvertFrom-Json).status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }) {
                    $realmReady = $true; break
                }
                Write-Info 'Waiting for realm...'; Start-Sleep -Seconds 10
            }
            if (-not $realmReady) { Write-Warn "Realm may still be provisioning -- continuing" }
            else { Write-Pass "Realm '$RealmName' is Ready" }
        } else {
            Write-Pass "Realm '$RealmName' already exists"
        }

        # STEP 26 - Create SAML client
        # ACS URL is /ibm/saml20/defaultSP (matches saml-ui-callback route on your cluster)
        Write-Step 'STEP 26 -- Create SAML Client for CPFS (Service Provider)'
        $spEntityId = "$CpConsoleUrl/ibm/saml20/initiatesso"
        $acsUrl     = "$CpConsoleUrl/ibm/saml20/defaultSP"
        Write-Info "SP Entity ID: $spEntityId"
        Write-Info "ACS URL     : $acsUrl"

        $kcToken    = Get-KcToken -KcPass $kcAdminPass
        $clientBody = @{
            clientId         = 'cpfs-sp'
            name             = 'CPFS Service Provider'
            protocol         = 'saml'
            enabled          = $true
            frontchannelLogout = $true
            fullScopeAllowed = $true
            redirectUris     = @("$CpConsoleUrl/*")
            attributes       = @{
                'saml.authnstatement'   = 'true'
                'saml.server.signature' = 'true'
                'saml.force.post.binding' = 'true'
                'saml.assertion.signature' = 'true'
                'saml_name_id_format'   = 'email'
                'saml.client.signature' = 'false'
                'saml.encrypt'          = 'false'
                'saml_signature_canonicalization_method' = 'http://www.w3.org/2001/10/xml-exc-c14n#'
                'saml.assertion.lifespan' = '300'
            }
            protocolMappers  = @(
                @{ name='email';     protocol='saml'; protocolMapper='saml-user-property-mapper';
                   config=@{ 'attribute.name'='email';     'attribute.nameformat'='Basic'; 'user.attribute'='email' } },
                @{ name='firstName'; protocol='saml'; protocolMapper='saml-user-property-mapper';
                   config=@{ 'attribute.name'='firstName'; 'attribute.nameformat'='Basic'; 'user.attribute'='firstName' } },
                @{ name='lastName';  protocol='saml'; protocolMapper='saml-user-property-mapper';
                   config=@{ 'attribute.name'='lastName';  'attribute.nameformat'='Basic'; 'user.attribute'='lastName' } },
                @{ name='groups';    protocol='saml'; protocolMapper='saml-group-membership-mapper';
                   config=@{ 'attribute.name'='groups'; 'attribute.nameformat'='Basic'; 'single'='false'; 'full.path'='false' } }
            )
        } | ConvertTo-Json -Depth 10

        $null = Invoke-KeycloakApi -Method POST -Path "/realms/$RealmName/clients" -Token $kcToken -Body $clientBody
        # Patch rootUrl + redirectUris
        $kcToken = Get-KcToken -KcPass $kcAdminPass
        $clients = Invoke-KeycloakApi -Method GET -Path "/realms/$RealmName/clients?clientId=cpfs-sp" -Token $kcToken
        if ($clients -and $clients.Count -gt 0) {
            $cid = $clients[0].id
            $upd = $clients[0]
            $upd.rootUrl = $CpConsoleUrl; $upd.baseUrl = '/ibm/saml20/initiatesso'; $upd.adminUrl = $CpConsoleUrl
            $upd | Add-Member -MemberType NoteProperty -Name 'redirectUris' -Value @("$CpConsoleUrl/*") -Force
            $null = Invoke-KeycloakApi -Method PUT -Path "/realms/$RealmName/clients/$cid" -Token $kcToken -Body ($upd | ConvertTo-Json -Depth 10)
        }
        Write-Pass "SAML client 'cpfs-sp' created and configured"

        # STEP 27 - Create test users
        Write-Step 'STEP 27 -- Create test users in Keycloak realm'
        $kcToken = Get-KcToken -KcPass $kcAdminPass
        foreach ($u in @(
            @{ username=$AdminUser;  email="$AdminUser@cpfs.local";  firstName='SAML'; lastName='Admin';  pwd=$AdminPassword  },
            @{ username=$ViewerUser; email="$ViewerUser@cpfs.local"; firstName='SAML'; lastName='Viewer'; pwd=$ViewerPassword }
        )) {
            $null = Invoke-KeycloakApi -Method POST -Path "/realms/$RealmName/users" -Token $kcToken -Body (
                @{ username=$u.username; email=$u.email; firstName=$u.firstName; lastName=$u.lastName; enabled=$true
                   credentials=@(@{ type='password'; value=$u.pwd; temporary=$false }) } | ConvertTo-Json -Depth 5)
            Write-Pass "User '$($u.username)' created ($($u.email))"
        }

        # STEP 28 - Create groups and assign users
        Write-Step 'STEP 28 -- Create groups and assign users'
        $kcToken = Get-KcToken -KcPass $kcAdminPass
        foreach ($g in @('cpfs-admins','cpfs-viewers')) {
            $null = Invoke-KeycloakApi -Method POST -Path "/realms/$RealmName/groups" -Token $kcToken -Body (@{ name=$g } | ConvertTo-Json)
            Write-Pass "Group '$g' created"
        }
        $kcToken = Get-KcToken -KcPass $kcAdminPass
        $groups  = Invoke-KeycloakApi -Method GET -Path "/realms/$RealmName/groups" -Token $kcToken
        $users   = Invoke-KeycloakApi -Method GET -Path "/realms/$RealmName/users"  -Token $kcToken
        $agId    = ($groups | Where-Object { $_.name -eq 'cpfs-admins'  } | Select-Object -First 1).id
        $vgId    = ($groups | Where-Object { $_.name -eq 'cpfs-viewers' } | Select-Object -First 1).id
        $auId    = ($users  | Where-Object { $_.username -eq $AdminUser  } | Select-Object -First 1).id
        $vuId    = ($users  | Where-Object { $_.username -eq $ViewerUser } | Select-Object -First 1).id
        $null    = Invoke-KeycloakApi -Method PUT -Path "/realms/$RealmName/users/$auId/groups/$agId" -Token $kcToken
        $null    = Invoke-KeycloakApi -Method PUT -Path "/realms/$RealmName/users/$vuId/groups/$vgId" -Token $kcToken
        Write-Pass "$AdminUser  --> group 'cpfs-admins'"
        Write-Pass "$ViewerUser --> group 'cpfs-viewers'"

    } # end if -not SkipKeycloak

    # Resolve KcBaseUrl if SkipKeycloak
    if ($SkipKeycloak) {
        $kcRouteHost = (& oc get route keycloak -n $RhssoNamespace -o jsonpath='{.spec.host}' 2>$null).Trim()
        if (-not $kcRouteHost) { throw "Keycloak route not found in '$RhssoNamespace'." }
        $script:KcBaseUrl = "https://$kcRouteHost"
        # RHBK uses cs-keycloak-initial-admin secret (not credential-keycloak)
        $kcSec       = Invoke-OcJson @('get', 'secret', 'cs-keycloak-initial-admin', '-n', $RhssoNamespace, '-o', 'json')
        $kcAdminPass = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($kcSec.data.password))
        Write-Pass "Keycloak URL (existing): $script:KcBaseUrl"
    }

    # STEP 29 - Fetch SAML metadata
    Write-Step "STEP 29 -- Fetch Keycloak SAML metadata XML for realm '$RealmName'"
    $metaUrl = "$script:KcBaseUrl/auth/realms/$RealmName/protocol/saml/descriptor"
    Write-Info "Metadata URL: $metaUrl"
    $deadline = (Get-Date).AddMinutes(3); $metaXml = $null
    while ((Get-Date) -lt $deadline) {
        try {
            $metaXml = (Invoke-WebRequest -Uri $metaUrl -SkipCertificateCheck -TimeoutSec 15 -UseBasicParsing).Content
            if ($metaXml -match 'EntityDescriptor') { break }
        } catch { Write-Info 'Metadata not ready, retrying...' }
        Start-Sleep -Seconds 10
    }
    if (-not ($metaXml -match 'EntityDescriptor')) { throw "Could not retrieve SAML metadata from $metaUrl" }
    Write-Pass 'SAML metadata XML retrieved'
    $metaB64    = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($metaXml))
    $spEntityId = "$CpConsoleUrl/ibm/saml20/initiatesso"

    # STEP 30 - Create CPFS IdpConfig CR
    Write-Step "STEP 30 -- Create CPFS IdpConfig CR: $IdpName"
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
      idpMetadata:         $metaB64
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

    # STEP 31 - Wait for IdpConfig Ready
    Write-Step 'STEP 31 -- Wait for IdpConfig to become Ready (up to 5 min)'
    $deadline = (Get-Date).AddMinutes(5); $idpReady = $false
    while ((Get-Date) -lt $deadline) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $idpRaw = & oc get idpconfig $IdpName -n $Namespace -o json 2>$null
        $ErrorActionPreference = $prev
        if ($idpRaw) {
            $idpPhase = ($idpRaw | ConvertFrom-Json).status.idpStatus
            Write-Info "IdpConfig status: $idpPhase"
            if ($idpPhase -match 'Enabled|Ready|Running') { $idpReady = $true; break }
        } else { Write-Info 'Waiting for IdpConfig status...' }
        Start-Sleep -Seconds 15
    }
    if (-not $idpReady) { Write-Warn 'IdpConfig may still be initialising -- continuing' }
    else                { Write-Pass "IdpConfig '$IdpName' is Ready" }

    # STEP 32 - Map groups to CPFS roles
    Write-Step 'STEP 32 -- Map Keycloak groups to CPFS roles'
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
---
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
    Write-Pass "cpfs-admins  --> ClusterRole 'icp:cloudpak:administrator'"
    Write-Pass "cpfs-viewers --> ClusterRole 'icp:cloudpak:viewer'"

} # end if -not SkipSaml

# =============================================================================
# STEP 33 -- FINAL SUMMARY BANNER
# =============================================================================
Write-Phase 'STEP 33 -- Complete Installation Summary'

# Re-read routes in case they were created during this run
$cpRoute = & oc get route cp-console -n $Namespace -o jsonpath='{.spec.host}' 2>$null
if ($cpRoute) { $CpConsoleUrl = "https://$cpRoute" }
if (-not $script:KcBaseUrl -and -not $SkipSaml) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $kcRouteHost = & oc get route keycloak -n $RhssoNamespace -o jsonpath='{.spec.host}' 2>$null
    $ErrorActionPreference = $prev
    if ($kcRouteHost) { $script:KcBaseUrl = "https://$kcRouteHost" }
}

Write-Host ''
Write-Host '  +============================================================+' -ForegroundColor Green
Write-Host '  |  INSTALLATION COMPLETE                                     |' -ForegroundColor Green
Write-Host '  +============================================================+' -ForegroundColor Green
Write-Host ''
Write-Host '  Infrastructure:' -ForegroundColor Cyan
Write-Host "    Cluster API    : $ClusterUrl" -ForegroundColor White
Write-Host "    StorageClass   : $StorageClass (default)" -ForegroundColor White
Write-Host "    CPFS namespace : $Namespace  channel: $Channel  size: $Size" -ForegroundColor White
Write-Host ''
Write-Host '  cp-console (IBM IAM):' -ForegroundColor Cyan
Write-Host "    URL            : $CpConsoleUrl" -ForegroundColor Green
Write-Host "    Login (native) : admin / (see secret platform-auth-idp-credentials)" -ForegroundColor White
if (-not $SkipSaml) {
    Write-Host ''
    Write-Host '  Keycloak SAML SSO:' -ForegroundColor Cyan
    Write-Host "    Admin console  : $script:KcBaseUrl/auth/admin" -ForegroundColor White
    Write-Host "    Realm          : $RealmName" -ForegroundColor White
    Write-Host "    SSO login URL  : $CpConsoleUrl/ibm/saml20/initiatesso" -ForegroundColor Green
    Write-Host ''
    Write-Host '  SAML Test Users:' -ForegroundColor Cyan
    Write-Host "    $AdminUser  / $AdminPassword" -ForegroundColor White
    Write-Host "      -> group: cpfs-admins -> ClusterAdministrator" -ForegroundColor White
    Write-Host "    $ViewerUser / $ViewerPassword" -ForegroundColor White
    Write-Host "      -> group: cpfs-viewers -> Viewer" -ForegroundColor White
}
Write-Host ''
Write-Host '  To test SAML login:' -ForegroundColor Cyan
Write-Host "    1. Open $CpConsoleUrl in your browser" -ForegroundColor White
Write-Host "    2. Click 'Log in with $IdpName'" -ForegroundColor White
Write-Host "    3. Enter: $AdminUser / $AdminPassword" -ForegroundColor White
Write-Host "    4. You will land in cp-console as ClusterAdministrator" -ForegroundColor White
Write-Host ''
Write-Host '  Verification commands:' -ForegroundColor Cyan
Write-Host "    oc get pods -n $Namespace" -ForegroundColor White
Write-Host "    oc get commonservice common-service -n $Namespace" -ForegroundColor White
Write-Host "    oc get idpconfig -n $Namespace" -ForegroundColor White
Write-Host "    oc get keycloak -n $RhssoNamespace" -ForegroundColor White
Write-Host "    oc extract secret/platform-auth-idp-credentials -n $Namespace --to=-" -ForegroundColor White
Write-Host ''
Write-Host '  Next steps:' -ForegroundColor Cyan
Write-Host '    - Change the default IAM admin password immediately' -ForegroundColor White
Write-Host '    - Change SAML test user passwords in Keycloak before production use' -ForegroundColor White
Write-Host '    - Set installPlanApproval: Manual for production operator upgrades' -ForegroundColor White
Write-Host '  +============================================================+' -ForegroundColor Green
Write-Host ''

# =============================================================================
# STEP 34 -- POST-INSTALL VERIFICATION
# =============================================================================
Write-Banner 'STEP 34 -- Post-Install Verification'

Write-Info '--- CommonService ---'
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& oc get commonservice common-service -n $Namespace 2>$null
$ErrorActionPreference = $prev

Write-Info '--- CPFS Pods ---'
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& oc get pods -n $Namespace -o wide 2>$null
$ErrorActionPreference = $prev

Write-Info '--- OperandRequest ---'
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& oc get operandrequest -n $Namespace 2>$null
$ErrorActionPreference = $prev

Write-Info '--- IdpConfig ---'
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& oc get idpconfig -n $Namespace 2>$null
$ErrorActionPreference = $prev

Write-Info '--- Keycloak ---'
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& oc get keycloak -n $RhssoNamespace 2>$null
$ErrorActionPreference = $prev

Write-Info '--- Warning events (last 10) ---'
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$warnEvents = & oc get events -n $Namespace --field-selector type=Warning --sort-by='.lastTimestamp' 2>$null
$ErrorActionPreference = $prev
if ($warnEvents) { $warnEvents | Select-Object -Last 10 | ForEach-Object { Write-Warn $_ } }
else             { Write-Pass 'No Warning events' }

Write-Pass 'All done.'
