<#
.SYNOPSIS
    End-to-end automated install of NFS StorageClass + IBM CPFS 4.x on OCP/Fyre.

.DESCRIPTION
    Phase 1 - NFS StorageClass
      1.  Login to OCP cluster
      2.  Check if StorageClass already exists
      3.  Configure NFS exports on master0 via oc debug node (no SSH)
      4.  Discover NFS server internal IP from OCP node object
      5.  Deploy nfs-subdir-external-provisioner (RBAC + StorageClass + Deployment)
      6.  Wait for provisioner pod Running
      7.  Smoke-test PVC bind/delete
      8.  Mark StorageClass as cluster default

    Phase 2 - IBM CPFS 4.x (https://www.ibm.com/docs/en/cloud-paks/foundational-services/4.x)
      9.  Pre-flight checks
      10. Check if CPFS is already installed (idempotent)
      11. Create operator namespace
      12. Create IBM entitlement-key pull secret
      13. Apply IBM Operator CatalogSource + wait for pod Ready
      14. Apply OperatorGroup + Subscription + wait for CSV Succeeded
      15. Apply CommonService CR + wait for phase Succeeded

.PARAMETER ConsoleUrl
    OCP web console URL - API URL is derived automatically.
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
    OCP node name to host NFS. Default: master0.<cluster-domain>

.PARAMETER NfsDir
    NFS export directory on the node. Default: /var/data/dynamic
    NOTE: Must be under /var on RHCOS nodes (root filesystem is read-only).

.PARAMETER NfsNamespace
    Namespace for the NFS provisioner. Default: managed-nfs-storage

.PARAMETER StorageClass
    StorageClass name to create. Default: managed-nfs-storage

.PARAMETER Namespace
    Namespace for CPFS operator. Default: ibm-common-services

.PARAMETER Channel
    OLM channel. e.g. v4.3, v4.6, v4.9, v4.10. Default: v4.6

.PARAMETER Size
    CommonService size: starterset|small|medium|large. Default: small

.PARAMETER SkipStorage
    Skip Phase 1 - use when a StorageClass already exists.

.PARAMETER SkipPreflight
    Skip pre-flight check step.

.EXAMPLE
    .\install-cpfs-end-to-end.ps1 `
        -ConsoleUrl     'https://console-openshift-console.apps.mycluster.cp.fyre.ibm.com' `
        -Password       'kubeadmin-password' `
        -EntitlementKey 'your-ibm-entitlement-key'

.EXAMPLE
    # Skip NFS setup (StorageClass already present)
    .\install-cpfs-end-to-end.ps1 -ConsoleUrl '...' -Password '...' -EntitlementKey '...' -SkipStorage

.LINK
    https://www.ibm.com/docs/en/cloud-paks/foundational-services/4.x
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConsoleUrl,

    [string]$ClusterUrl     = '',
    [string]$Username       = 'kubeadmin',

    [Parameter(Mandatory = $true)]
    [string]$Password,

    [Parameter(Mandatory = $true)]
    [string]$EntitlementKey,

    [string]$NfsHost        = '',
    [string]$NfsDir         = '/var/data/dynamic',
    [string]$NfsNamespace   = 'managed-nfs-storage',
    [string]$StorageClass   = 'managed-nfs-storage',
    [string]$Namespace      = 'ibm-common-services',
    [string]$Channel        = 'v4.6',
    [string]$Size           = 'small',
    [switch]$SkipStorage,
    [switch]$SkipPreflight
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

# Runs a shell command on an OCP node via oc debug + nsenter (no SSH, writable host fs).
# Uses nsenter instead of chroot because RHCOS root (/) is a read-only composefs.
function Invoke-OcNodeDebug([string]$NodeName, [string]$Command) {
    # oc debug writes "Starting pod/..." to stderr which triggers ErrorActionPreference=Stop.
    # Temporarily relax to Continue so the command can complete normally.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & oc debug "node/$NodeName" -- nsenter -a -t 1 -- bash -c $Command 2>&1
        $rc  = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $outStr = ($out -join "`n")
    if ($rc -ne 0 -and $outStr -notmatch 'NFS_CONFIGURED_OK') {
        $errors = $out | Where-Object { $_ -notmatch 'Starting pod|Removing debug pod' }
        throw "oc debug node/$NodeName failed (exit $rc).`nOutput: $($errors -join "`n")"
    }
    return $outStr
}

# ---------------------------------------------------------------------------
# Derive URLs and node names
# ---------------------------------------------------------------------------
if (-not $ClusterUrl) {
    if ($ConsoleUrl -match 'apps\.(.+)$') {
        $clusterDomain = $Matches[1].TrimEnd('/')
        $ClusterUrl = "https://api.$clusterDomain`:6443"
    } else {
        throw "Cannot derive API URL from ConsoleUrl '$ConsoleUrl'. Supply -ClusterUrl explicitly."
    }
}

if (-not $NfsHost) {
    if ($ClusterUrl -match 'api\.(.+):\d+') {
        $NfsHost = "master0.$($Matches[1])"
    } else {
        throw "Cannot derive NFS node from ClusterUrl '$ClusterUrl'. Supply -NfsHost explicitly."
    }
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '+--------------------------------------------------------------+' -ForegroundColor Cyan
Write-Host '|  IBM CPFS 4.x -- Automated Install (NFS Storage + CPFS)     |' -ForegroundColor Cyan
Write-Host '+--------------------------------------------------------------+' -ForegroundColor Cyan
Write-Info "Cluster      : $ClusterUrl"
Write-Info "NFS node     : $NfsHost"
Write-Info "NFS dir      : $NfsDir"
Write-Info "StorageClass : $StorageClass"
Write-Info "Namespace    : $Namespace"
Write-Info "Channel      : $Channel"
Write-Info "Size         : $Size"

# ---------------------------------------------------------------------------
# STEP 1 - Login
# ---------------------------------------------------------------------------
Write-Banner 'STEP 1/15 -- Login to OCP cluster'
Invoke-Oc @('login', $ClusterUrl, '-u', $Username, '-p', $Password, '--insecure-skip-tls-verify=true')
Write-Pass "Logged in as: $(& oc whoami)"

# ===========================================================================
# PHASE 1 - NFS StorageClass
# ===========================================================================
if ($SkipStorage) {
    Write-Warn 'SkipStorage set -- skipping NFS phase'
} else {
    Write-Banner 'PHASE 1 -- NFS StorageClass Setup'

    # STEP 2 - Check existing StorageClasses
    Write-Step 'STEP 2/15 -- Check existing StorageClasses'
    $existingSc = & oc get storageclass -o name 2>$null
    if ($existingSc) {
        Write-Warn "StorageClass(es) already exist: $existingSc"
        Write-Warn 'Skipping NFS setup. Use -SkipStorage to suppress this check.'
        $SkipStorage = $true
    } else {
        Write-Info 'No StorageClass found -- proceeding with NFS setup.'
    }
}

if (-not $SkipStorage) {
    # STEP 3 - Configure NFS on node via oc debug + nsenter
    Write-Step 'STEP 3/15 -- Configure NFS exports on node via oc debug'
    Write-Info "Target node: $NfsHost"

    $nfsCmd = "mkdir -p $NfsDir && " +
              "(grep -qF '$NfsDir' /etc/exports || " +
              "echo '$NfsDir 10.0.0.0/8(rw,sync,no_wdelay,no_root_squash,insecure)' >> /etc/exports) && " +
              "sed -i '/^\s*$/d' /etc/exports && " +
              "sort -u /etc/exports -o /etc/exports && " +
              "exportfs -ra && " +
              "(systemctl restart nfs-server 2>/dev/null || systemctl restart nfs 2>/dev/null || true) && " +
              "echo NFS_CONFIGURED_OK"

    $result = Invoke-OcNodeDebug -NodeName $NfsHost -Command $nfsCmd
    if ($result -notmatch 'NFS_CONFIGURED_OK') {
        throw "NFS configuration on $NfsHost did not complete. Output: $result"
    }
    Write-Pass "NFS exports configured on $NfsHost ($NfsDir)"

    # STEP 4 - Get NFS server IP from OCP node object
    Write-Step 'STEP 4/15 -- Discover NFS server internal IP'
    $nfsIp = (& oc get node $NfsHost -o "jsonpath={.status.addresses[?(@.type=='InternalIP')].address}").Trim()
    if (-not ($nfsIp -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$')) {
        throw "Could not determine InternalIP of node $NfsHost. Got: '$nfsIp'"
    }
    Write-Pass "NFS server IP: $nfsIp"

    # STEP 5 - Deploy nfs-subdir-external-provisioner
    Write-Step 'STEP 5/15 -- Deploy NFS subdir external provisioner'

    # Namespace
    & oc new-project $NfsNamespace 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Info "Namespace '$NfsNamespace' already exists -- continuing"
    } else {
        Write-Pass "Namespace '$NfsNamespace' created"
    }

    # RBAC
    $rbacUrl = 'https://raw.githubusercontent.com/kubernetes-sigs/nfs-subdir-external-provisioner/master/deploy/rbac.yaml'
    $rbacYaml = (Invoke-WebRequest -Uri $rbacUrl -UseBasicParsing).Content
    $rbacYaml = $rbacYaml -replace 'namespace:\s*\S+', "namespace: $NfsNamespace"
    $rbacYaml | & oc apply -f -
    if ($LASTEXITCODE -ne 0) { throw 'Failed to apply NFS RBAC.' }

    # SCC
    Invoke-Oc @('adm', 'policy', 'add-scc-to-user', 'hostmount-anyuid',
        "system:serviceaccount:${NfsNamespace}:nfs-client-provisioner")

    # StorageClass
    $classUrl = 'https://raw.githubusercontent.com/kubernetes-sigs/nfs-subdir-external-provisioner/master/deploy/class.yaml'
    $classYaml = (Invoke-WebRequest -Uri $classUrl -UseBasicParsing).Content
    $classYaml = $classYaml -replace '(?m)(^\s*name:\s*)managed-nfs-storage', "`${1}$StorageClass"
    $classYaml = $classYaml -replace '(?m)(^\s*storageclass\.kubernetes\.io/is-default-class:).*', '${1} "false"'
    $classYaml | & oc apply -f -
    if ($LASTEXITCODE -ne 0) { throw 'Failed to apply StorageClass.' }

    # Deployment - patch NFS server IP and path
    $deployUrl = 'https://raw.githubusercontent.com/kubernetes-sigs/nfs-subdir-external-provisioner/master/deploy/deployment.yaml'
    $deployYaml = (Invoke-WebRequest -Uri $deployUrl -UseBasicParsing).Content
    $deployYaml = $deployYaml -replace 'namespace:\s*\S+', "namespace: $NfsNamespace"
    $deployYaml = $deployYaml -replace '10\.3\.243\.101', $nfsIp
    $deployYaml = $deployYaml -replace '/ifs/kubernetes', $NfsDir
    $deployYaml | & oc apply -n $NfsNamespace -f -
    if ($LASTEXITCODE -ne 0) { throw 'Failed to apply NFS provisioner Deployment.' }
    Write-Pass 'NFS provisioner manifests applied'

    # STEP 6 - Wait for provisioner pod Running
    Write-Step 'STEP 6/15 -- Wait for NFS provisioner pod Running (up to 3 min)'
    $nfsDeadline = (Get-Date).AddMinutes(3)
    $nfsReady = $false
    while ((Get-Date) -lt $nfsDeadline) {
        $podsRaw = & oc get pods -n $NfsNamespace -o json 2>$null
        if ($podsRaw) {
            $pods = $podsRaw | ConvertFrom-Json
            $running = @($pods.items | Where-Object { $_.status.phase -eq 'Running' }).Count
            if ($running -ge 1) { $nfsReady = $true; break }
        }
        Write-Info 'Waiting for NFS provisioner pod...'
        Start-Sleep -Seconds 10
    }
    if (-not $nfsReady) {
        & oc get pods -n $NfsNamespace
        throw 'NFS provisioner pod did not start in time.'
    }
    Write-Pass 'NFS provisioner pod is Running'

    # STEP 7 - Smoke-test PVC
    Write-Step 'STEP 7/15 -- Smoke-test PVC'
    $pvcYaml = @"
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: nfs-smoke-test
spec:
  storageClassName: $StorageClass
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: 100Mi
"@
    $pvcYaml | & oc apply -n $NfsNamespace -f -
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create smoke-test PVC.' }

    $pvcDeadline = (Get-Date).AddMinutes(2)
    $pvcBound = $false
    while ((Get-Date) -lt $pvcDeadline) {
        $pvcStatus = (& oc get pvc nfs-smoke-test -n $NfsNamespace -o jsonpath='{.status.phase}' 2>$null)
        if ($pvcStatus -eq 'Bound') { $pvcBound = $true; break }
        Write-Info 'Waiting for PVC to bind...'
        Start-Sleep -Seconds 5
    }
    & oc delete pvc nfs-smoke-test -n $NfsNamespace --ignore-not-found=true 2>$null | Out-Null
    if (-not $pvcBound) {
        throw "Smoke-test PVC did not bind -- check NFS server ${nfsIp}:${NfsDir} is reachable from pods."
    }
    Write-Pass 'PVC smoke test passed -- StorageClass is working'

    # STEP 8 - Mark as default StorageClass
    Write-Step 'STEP 8/15 -- Set as default StorageClass'
    Invoke-Oc @('annotate', 'storageclass', $StorageClass,
        'storageclass.kubernetes.io/is-default-class=true', '--overwrite')
    Write-Pass "'$StorageClass' is now the default StorageClass"
}

# ===========================================================================
# PHASE 2 - IBM CPFS 4.x Installation
# ===========================================================================
Write-Banner 'PHASE 2 -- IBM Cloud Pak Foundational Services 4.x'

# STEP 9 - Pre-flight checks
if (-not $SkipPreflight) {
    Write-Step 'STEP 9/15 -- Pre-flight checks'
    & node "$PSScriptRoot/preflight-check.js"
    if ($LASTEXITCODE -ne 0) { throw 'Pre-flight checks failed -- fix issues above and re-run.' }
} else {
    Write-Warn 'SkipPreflight set -- skipping pre-flight checks'
}

# STEP 10 - Check if CPFS is already installed (idempotent)
Write-Step 'STEP 10/15 -- Check if CPFS is already installed'
$csvCheck = & oc get csv -A -o json 2>$null | ConvertFrom-Json
$existingCsv = $csvCheck.items | Where-Object {
    $_.metadata.name -like 'ibm-common-service-operator.v*' -and $_.status.phase -eq 'Succeeded'
}
if ($existingCsv) {
    Write-Pass "CPFS already installed: $($existingCsv.metadata.name) -- nothing to do."
    Write-Info "Check status: oc get commonservice common-service -n $Namespace"
    exit 0
}
Write-Info 'CPFS not installed -- proceeding.'

# STEP 11 - Namespace
Write-Step 'STEP 11/15 -- Ensure operator namespace'
& oc create namespace $Namespace --dry-run=client -o yaml | & oc apply -f -
if ($LASTEXITCODE -ne 0) { throw 'Failed to create/apply namespace.' }
Write-Pass "Namespace '$Namespace' ready"

# STEP 12 - Entitlement secret
Write-Step 'STEP 12/15 -- IBM Entitlement Key pull secret'
& oc create secret docker-registry ibm-entitlement-key `
    --docker-server=cp.icr.io `
    --docker-username=cp `
    "--docker-password=$EntitlementKey" `
    '--docker-email=cpfs-install@cluster.local' `
    -n $Namespace `
    --dry-run=client -o yaml | & oc apply -f -
if ($LASTEXITCODE -ne 0) { throw 'Failed to create/apply entitlement secret.' }
Write-Pass "Secret 'ibm-entitlement-key' ready in '$Namespace'"

# STEP 13 - IBM Operator CatalogSource
Write-Step 'STEP 13/15 -- IBM Operator CatalogSource'
$catalogYaml = @"
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
"@
$catalogYaml | & oc apply -f -
if ($LASTEXITCODE -ne 0) { throw 'Failed to apply CatalogSource.' }

Write-Info 'Waiting for catalog pod Ready (up to 5 min)...'
$catDeadline = (Get-Date).AddMinutes(5)
$catReady = $false
while ((Get-Date) -lt $catDeadline) {
    $catRaw = & oc get pods -n openshift-marketplace -l olm.catalogSource=ibm-operator-catalog -o json 2>$null
    if ($catRaw) {
        $catPods = $catRaw | ConvertFrom-Json
        $ready = @($catPods.items | Where-Object {
            ($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' })
        }).Count
        if ($ready -ge 1) { $catReady = $true; break }
    }
    Write-Info 'Waiting for catalog pod...'
    Start-Sleep -Seconds 15
}
if (-not $catReady) {
    & oc get pods -n openshift-marketplace | Select-String 'ibm-operator-catalog'
    throw 'IBM Operator Catalog pod did not become Ready in time.'
}
Write-Pass 'IBM Operator Catalog pod is Ready'

# STEP 14 - OperatorGroup + Subscription
Write-Step 'STEP 14/15 -- OperatorGroup + Subscription'
$ogYaml = @"
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ibm-common-services-operatorgroup
  namespace: $Namespace
spec:
  targetNamespaces:
  - $Namespace
"@
$ogYaml | & oc apply -f -
if ($LASTEXITCODE -ne 0) { throw 'Failed to apply OperatorGroup.' }
Write-Pass "OperatorGroup ready in '$Namespace'"

$subYaml = @"
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
"@
$subYaml | & oc apply -f -
if ($LASTEXITCODE -ne 0) { throw 'Failed to apply Subscription.' }
Write-Pass "Subscription created on channel '$Channel'"

Write-Info 'Waiting for CSV Succeeded (up to 10 min)...'
$csvDeadline = (Get-Date).AddMinutes(10)
$csv = $null
while ((Get-Date) -lt $csvDeadline) {
    $csvList = Invoke-OcJson @('get', 'csv', '-n', $Namespace, '-o', 'json')
    $csv = @($csvList.items | Where-Object { $_.metadata.name -like 'ibm-common-service-operator.v*' }) | Select-Object -First 1
    if ($csv) {
        Write-Info "CSV: $($csv.metadata.name)  phase=$($csv.status.phase)"
        if ($csv.status.phase -eq 'Succeeded') { break }
    } else {
        Write-Info 'Waiting for CSV to appear...'
    }
    Start-Sleep -Seconds 20
}
if (-not $csv) { throw 'Timed out -- CSV ibm-common-service-operator never appeared.' }
if ($csv.status.phase -ne 'Succeeded') {
    & oc get installplan -n $Namespace
    & oc get events -n $Namespace --sort-by='.lastTimestamp' | Select-Object -Last 20
    throw "CSV did not reach Succeeded within 10 minutes."
}
Write-Pass "CSV '$($csv.metadata.name)' Succeeded"

# STEP 15 - CommonService CR
Write-Step 'STEP 15/15 -- CommonService CR'
$csYaml = @"
apiVersion: operator.ibm.com/v3
kind: CommonService
metadata:
  name: common-service
  namespace: $Namespace
spec:
  size: $Size
  services:
  - name: ibm-iam-operator
    spec: {}
  - name: ibm-licensing-operator
    spec: {}
  - name: ibm-cert-manager-operator
    spec: {}
"@
$csYaml | & oc apply -f -
if ($LASTEXITCODE -ne 0) { throw 'Failed to apply CommonService CR.' }
Write-Pass 'CommonService CR applied'

Write-Info 'Waiting for CommonService phase = Succeeded (up to 20 min)...'
$csDeadline = (Get-Date).AddMinutes(20)
$csPhase = ''
while ((Get-Date) -lt $csDeadline) {
    $csPhase = (& oc get commonservice common-service -n $Namespace -o jsonpath='{.status.phase}' 2>$null)
    Write-Info "CommonService phase: $csPhase"
    if ($csPhase -eq 'Succeeded') { break }
    Start-Sleep -Seconds 30
}
if ($csPhase -ne 'Succeeded') {
    Write-Warn "CommonService phase is '$csPhase' after 20 min -- showing ODLM logs:"
    & oc logs -n $Namespace -l 'app.kubernetes.io/name=operand-deployment-lifecycle-manager' --tail=40 2>$null
    Write-Warn 'Install may still converge -- monitor with: oc get commonservice -n ibm-common-services'
} else {
    Write-Pass 'CommonService phase = Succeeded'
}

# ---------------------------------------------------------------------------
# Post-install verification
# ---------------------------------------------------------------------------
Write-Banner 'Post-Install Verification'

Write-Info '--- Pods ---'
& oc get pods -n $Namespace -o wide

Write-Info ''
Write-Info '--- OperandRegistry ---'
& oc get operandregistry -n $Namespace 2>$null

Write-Info ''
Write-Info '--- OperandConfig ---'
& oc get operandconfig -n $Namespace 2>$null

Write-Info ''
Write-Info '--- Warning events (last 10) ---'
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$warnEvents = & oc get events -n $Namespace --field-selector type=Warning --sort-by='.lastTimestamp' 2>$null
$ErrorActionPreference = $prev
if ($warnEvents) { $warnEvents | Select-Object -Last 10 | ForEach-Object { Write-Warn $_ } }
else             { Write-Pass 'No Warning events' }

Write-Info ''
Write-Info '--- cp-console route ---'
$route = & oc get route -n $Namespace 2>$null | Select-String 'cp-console'
if ($route) { Write-Pass "cp-console: $route" }
else        { Write-Warn 'cp-console route not yet available -- IAM may still be starting' }

Write-Info ''
Write-Info '--- IAM admin credentials ---'
$credSecret = & oc get secret platform-auth-idp-credentials -n $Namespace -o name 2>$null
if ($credSecret) {
    & oc extract secret/platform-auth-idp-credentials -n $Namespace --to=- 2>$null
} else {
    Write-Warn "platform-auth-idp-credentials not yet present -- retry after IAM finishes:"
    Write-Warn "  oc extract secret/platform-auth-idp-credentials -n $Namespace --to=-"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '+--------------------------------------------------------------+' -ForegroundColor Cyan
if ($csPhase -eq 'Succeeded') {
    Write-Host '|  [OK] INSTALL COMPLETE -- CPFS 4.x is running               |' -ForegroundColor Green
} else {
    Write-Host '|  [!!] INSTALL SUBMITTED -- CommonService still converging    |' -ForegroundColor Yellow
}
Write-Host '+--------------------------------------------------------------+' -ForegroundColor Cyan
Write-Host "  Cluster      : $ClusterUrl" -ForegroundColor Cyan
Write-Host "  Namespace    : $Namespace" -ForegroundColor Cyan
Write-Host "  Channel      : $Channel" -ForegroundColor Cyan
Write-Host "  Size         : $Size" -ForegroundColor Cyan
Write-Host "  StorageClass : $StorageClass" -ForegroundColor Cyan
Write-Host '+--------------------------------------------------------------+' -ForegroundColor Cyan
Write-Host '  Next steps:' -ForegroundColor Cyan
Write-Host '  - Change the default IAM admin password immediately' -ForegroundColor Cyan
Write-Host '  - Set installPlanApproval: Manual for production upgrades' -ForegroundColor Cyan
Write-Host "  - Monitor: oc get pods -n $Namespace -w" -ForegroundColor Cyan
Write-Host '+--------------------------------------------------------------+' -ForegroundColor Cyan
Write-Host ''
