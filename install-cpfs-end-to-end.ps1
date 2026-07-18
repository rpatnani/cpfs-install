<#
.SYNOPSIS
    End-to-end automated install of NFS StorageClass + IBM CPFS 4.x + cp-console on OCP/Fyre.

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
      9.  Install Red Hat cert-manager operator (required prereq for cp-console)
      10. Wait for cert-manager pods Ready
      11. Pre-flight checks
      12. Check if CPFS is already installed (idempotent)
      13. Create operator namespace
      14. Create IBM entitlement-key pull secret
      15. Apply IBM Operator CatalogSource + wait for pod Ready
      16. Apply OperatorGroup + Subscription + wait for CSV Succeeded
      17. Apply CommonService CR + wait for phase Succeeded

    Phase 3 - cp-console (IAM / Identity Management stack)
      18. Apply OperandRequest to deploy IAM, CommonUI, PostgreSQL, Management Ingress
      19. Wait for PostgreSQL cluster healthy
      20. Wait for all IAM pods Running
      21. Print cp-console URL + extract admin credentials

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

.PARAMETER SkipCertManager
    Skip cert-manager install - use when already installed on the cluster.

.PARAMETER SkipPreflight
    Skip pre-flight check step.

.PARAMETER SkipConsole
    Skip Phase 3 - install CPFS only, without deploying cp-console / IAM stack.

.EXAMPLE
    .\install-cpfs-end-to-end.ps1 `
        -ConsoleUrl     'https://console-openshift-console.apps.mycluster.cp.fyre.ibm.com' `
        -Password       'kubeadmin-password' `
        -EntitlementKey 'your-ibm-entitlement-key'

.EXAMPLE
    # Skip NFS setup (StorageClass already present)
    .\install-cpfs-end-to-end.ps1 -ConsoleUrl '...' -Password '...' -EntitlementKey '...' -SkipStorage

.EXAMPLE
    # Install CPFS only, no cp-console
    .\install-cpfs-end-to-end.ps1 -ConsoleUrl '...' -Password '...' -EntitlementKey '...' -SkipConsole

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
    [switch]$SkipCertManager,
    [switch]$SkipPreflight,
    [switch]$SkipConsole
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
# Uses nsenter because RHCOS root (/) is a read-only composefs.
function Invoke-OcNodeDebug([string]$NodeName, [string]$Command) {
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
Write-Host '|  IBM CPFS 4.x -- Automated Install (NFS + CPFS + cp-console) |' -ForegroundColor Cyan
Write-Host '+--------------------------------------------------------------+' -ForegroundColor Cyan
Write-Info "Cluster      : $ClusterUrl"
Write-Info "NFS node     : $NfsHost"
Write-Info "NFS dir      : $NfsDir"
Write-Info "StorageClass : $StorageClass"
Write-Info "Namespace    : $Namespace"
Write-Info "Channel      : $Channel"
Write-Info "Size         : $Size"
Write-Info "SkipStorage  : $SkipStorage  |  SkipConsole: $SkipConsole"

# ---------------------------------------------------------------------------
# STEP 1 - Login
# ---------------------------------------------------------------------------
Write-Banner 'STEP 1 -- Login to OCP cluster'
Invoke-Oc @('login', $ClusterUrl, '-u', $Username, '-p', $Password, '--insecure-skip-tls-verify=true')
Write-Pass "Logged in as: $(& oc whoami)"

# ===========================================================================
# PHASE 1 - NFS StorageClass
# ===========================================================================
if ($SkipStorage) {
    Write-Warn 'SkipStorage set -- skipping NFS phase'
} else {
    Write-Banner 'PHASE 1 -- NFS StorageClass Setup'

    Write-Step 'STEP 2 -- Check existing StorageClasses'
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
    Write-Step 'STEP 3 -- Configure NFS exports on node via oc debug'
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
    if ($result -notmatch 'NFS_CONFIGURED_OK') { throw "NFS config failed: $result" }
    Write-Pass "NFS exports configured on $NfsHost ($NfsDir)"

    # STEP 4 - Get NFS server IP
    Write-Step 'STEP 4 -- Discover NFS server internal IP'
    $nfsIp = (& oc get node $NfsHost -o "jsonpath={.status.addresses[?(@.type=='InternalIP')].address}").Trim()
    if (-not ($nfsIp -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$')) {
        throw "Could not determine InternalIP of node $NfsHost. Got: '$nfsIp'"
    }
    Write-Pass "NFS server IP: $nfsIp"

    # STEP 5 - Deploy nfs-subdir-external-provisioner
    Write-Step 'STEP 5 -- Deploy NFS subdir external provisioner'
    & oc new-project $NfsNamespace 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Info "Namespace '$NfsNamespace' already exists" }
    else { Write-Pass "Namespace '$NfsNamespace' created" }

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

    # STEP 6 - Wait for provisioner pod Running
    Write-Step 'STEP 6 -- Wait for NFS provisioner pod Running (up to 3 min)'
    $deadline = (Get-Date).AddMinutes(3); $ready = $false
    while ((Get-Date) -lt $deadline) {
        $raw = & oc get pods -n $NfsNamespace -o json 2>$null
        if ($raw) {
            $running = @(($raw | ConvertFrom-Json).items | Where-Object { $_.status.phase -eq 'Running' }).Count
            if ($running -ge 1) { $ready = $true; break }
        }
        Write-Info 'Waiting for NFS provisioner pod...'; Start-Sleep -Seconds 10
    }
    if (-not $ready) { & oc get pods -n $NfsNamespace; throw 'NFS pod did not start in time.' }
    Write-Pass 'NFS provisioner pod is Running'

    # STEP 7 - Smoke-test PVC
    Write-Step 'STEP 7 -- Smoke-test PVC'
    @"
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
"@ | & oc apply -n $NfsNamespace -f -
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create smoke-test PVC.' }
    $deadline = (Get-Date).AddMinutes(2); $bound = $false
    while ((Get-Date) -lt $deadline) {
        if ((& oc get pvc nfs-smoke-test -n $NfsNamespace -o jsonpath='{.status.phase}' 2>$null) -eq 'Bound') { $bound = $true; break }
        Write-Info 'Waiting for PVC to bind...'; Start-Sleep -Seconds 5
    }
    & oc delete pvc nfs-smoke-test -n $NfsNamespace --ignore-not-found=true 2>$null | Out-Null
    if (-not $bound) { throw "PVC did not bind -- NFS server ${nfsIp}:${NfsDir} may not be reachable." }
    Write-Pass 'PVC smoke test passed'

    # STEP 8 - Mark as default StorageClass
    Write-Step 'STEP 8 -- Set as default StorageClass'
    Invoke-Oc @('annotate', 'storageclass', $StorageClass,
        'storageclass.kubernetes.io/is-default-class=true', '--overwrite')
    Write-Pass "'$StorageClass' is now the default StorageClass"
}

# ===========================================================================
# PHASE 2 - IBM CPFS 4.x Installation
# ===========================================================================
Write-Banner 'PHASE 2 -- IBM Cloud Pak Foundational Services 4.x'

# STEP 9 - Red Hat cert-manager (required prereq for cp-console / PostgreSQL)
if ($SkipCertManager) {
    Write-Warn 'SkipCertManager set -- skipping cert-manager install'
} else {
    Write-Step 'STEP 9 -- Red Hat cert-manager operator (prereq for cp-console)'
    $certCrd = & oc get crd certificates.cert-manager.io -o name 2>$null
    if ($certCrd) {
        Write-Pass 'cert-manager CRDs already present -- skipping install'
    } else {
        & oc create namespace cert-manager-operator --dry-run=client -o yaml | & oc apply -f -
        @"
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator
  namespace: cert-manager-operator
spec:
  targetNamespaces:
  - cert-manager-operator
"@ | & oc apply -f -
        @"
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1
  installPlanApproval: Automatic
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
"@ | & oc apply -f -
        if ($LASTEXITCODE -ne 0) { throw 'Failed to apply cert-manager Subscription.' }

        # STEP 10 - Wait for cert-manager pods Ready
        Write-Step 'STEP 10 -- Wait for cert-manager pods Ready (up to 5 min)'
        $deadline = (Get-Date).AddMinutes(5); $cmReady = $false
        while ((Get-Date) -lt $deadline) {
            $raw = & oc get pods -n cert-manager -o json 2>$null
            if ($raw) {
                $pods = ($raw | ConvertFrom-Json).items
                $running = @($pods | Where-Object { $_.status.phase -eq 'Running' }).Count
                if ($running -ge 3) { $cmReady = $true; break }    # cert-manager + cainjector + webhook
            }
            Write-Info 'Waiting for cert-manager pods...'; Start-Sleep -Seconds 15
        }
        if (-not $cmReady) {
            & oc get pods -n cert-manager-operator; & oc get pods -n cert-manager
            throw 'cert-manager pods did not start in time.'
        }
        Write-Pass 'cert-manager pods are Ready'
    }
}

# STEP 11 - Pre-flight checks
if (-not $SkipPreflight) {
    Write-Step 'STEP 11 -- Pre-flight checks'
    & node "$PSScriptRoot/preflight-check.js"
    if ($LASTEXITCODE -ne 0) { throw 'Pre-flight checks failed -- fix issues above and re-run.' }
} else {
    Write-Warn 'SkipPreflight set -- skipping pre-flight checks'
}

# STEP 12 - Idempotency check
Write-Step 'STEP 12 -- Check if CPFS is already installed'
$csvCheck = & oc get csv -A -o json 2>$null | ConvertFrom-Json
$existingCsv = $csvCheck.items | Where-Object {
    $_.metadata.name -like 'ibm-common-service-operator.v*' -and $_.status.phase -eq 'Succeeded'
}
if ($existingCsv) {
    Write-Pass "CPFS already installed: $($existingCsv.metadata.name)"
} else {
    Write-Info 'CPFS not installed -- proceeding.'

    # STEP 13 - Namespace
    Write-Step 'STEP 13 -- Ensure operator namespace'
    & oc create namespace $Namespace --dry-run=client -o yaml | & oc apply -f -
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create/apply namespace.' }
    Write-Pass "Namespace '$Namespace' ready"

    # STEP 14 - Entitlement secret
    Write-Step 'STEP 14 -- IBM Entitlement Key pull secret'
    & oc create secret docker-registry ibm-entitlement-key `
        --docker-server=cp.icr.io `
        --docker-username=cp `
        "--docker-password=$EntitlementKey" `
        '--docker-email=cpfs-install@cluster.local' `
        -n $Namespace `
        --dry-run=client -o yaml | & oc apply -f -
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create/apply entitlement secret.' }
    Write-Pass "Secret 'ibm-entitlement-key' ready in '$Namespace'"

    # STEP 15 - IBM Operator CatalogSource
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
    Write-Info 'Waiting for catalog pod Ready (up to 5 min)...'
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

    # STEP 16 - OperatorGroup + Subscription
    Write-Step 'STEP 16 -- OperatorGroup + Subscription'
    @"
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ibm-common-services-operatorgroup
  namespace: $Namespace
spec:
  targetNamespaces:
  - $Namespace
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

    Write-Info 'Waiting for CSV Succeeded (up to 10 min)...'
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
    if (-not $csv) { throw 'Timed out -- CSV never appeared.' }
    if ($csv.status.phase -ne 'Succeeded') {
        & oc get installplan -n $Namespace; throw 'CSV did not reach Succeeded.'
    }
    Write-Pass "CSV '$($csv.metadata.name)' Succeeded"

    # STEP 17 - CommonService CR
    Write-Step 'STEP 17 -- CommonService CR'
    @"
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
"@ | & oc apply -f -
    if ($LASTEXITCODE -ne 0) { throw 'Failed to apply CommonService CR.' }
    Write-Info 'Waiting for CommonService phase = Succeeded (up to 20 min)...'
    $deadline = (Get-Date).AddMinutes(20); $csPhase = ''
    while ((Get-Date) -lt $deadline) {
        $csPhase = (& oc get commonservice common-service -n $Namespace -o jsonpath='{.status.phase}' 2>$null)
        Write-Info "CommonService phase: $csPhase"
        if ($csPhase -eq 'Succeeded') { break }
        Start-Sleep -Seconds 30
    }
    if ($csPhase -ne 'Succeeded') {
        Write-Warn "CommonService did not reach Succeeded in 20 min"
        & oc logs -n $Namespace -l 'app.kubernetes.io/name=operand-deployment-lifecycle-manager' --tail=30 2>$null
    } else { Write-Pass 'CommonService phase = Succeeded' }
}

# ===========================================================================
# PHASE 3 - cp-console (IAM / Identity Management stack)
# ===========================================================================
if ($SkipConsole) {
    Write-Warn 'SkipConsole set -- skipping cp-console / IAM deployment'
} else {
    Write-Banner 'PHASE 3 -- cp-console (IAM Stack)'

    # STEP 18 - OperandRequest for full IAM stack
    Write-Step 'STEP 18 -- Apply OperandRequest for IAM + cp-console stack'
    $orExisting = & oc get operandrequest common-service -n $Namespace -o name 2>$null
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

    # STEP 19 - Wait for PostgreSQL cluster healthy
    Write-Step 'STEP 19 -- Wait for PostgreSQL cluster healthy (up to 10 min)'
    $deadline = (Get-Date).AddMinutes(10); $pgReady = $false
    while ((Get-Date) -lt $deadline) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $pgRaw = & oc get cluster common-service-db -n $Namespace -o json 2>$null
        $ErrorActionPreference = $prev
        if ($pgRaw) {
            $pg = $pgRaw | ConvertFrom-Json
            $pgPhase = $pg.status.phase
            Write-Info "PostgreSQL phase: $pgPhase"
            if ($pgPhase -match 'healthy') { $pgReady = $true; break }
            # If stuck on missing CA secret, trigger a reconcile
            if ($pgPhase -match 'Unable to create') {
                & oc annotate cluster common-service-db -n $Namespace "reconcile=$(Get-Date -Format 'yyyyMMddHHmmss')" --overwrite 2>$null | Out-Null
            }
        } else {
            Write-Info 'Waiting for PostgreSQL cluster CR to appear...'
        }
        Start-Sleep -Seconds 20
    }
    if (-not $pgReady) {
        Write-Warn 'PostgreSQL cluster not yet healthy -- install may still converge'
        & oc get cluster -n $Namespace 2>$null
    } else { Write-Pass 'PostgreSQL cluster is healthy' }

    # STEP 20 - Wait for IAM pods Running
    Write-Step 'STEP 20 -- Wait for IAM pods Running (up to 15 min)'
    $iamPods = @('platform-auth-service', 'platform-identity-management', 'platform-identity-provider', 'common-web-ui')
    $deadline = (Get-Date).AddMinutes(15); $iamReady = $false
    while ((Get-Date) -lt $deadline) {
        $raw = & oc get pods -n $Namespace -o json 2>$null
        if ($raw) {
            $pods = ($raw | ConvertFrom-Json).items
            $readyCount = 0
            foreach ($name in $iamPods) {
                $pod = $pods | Where-Object { $_.metadata.name -like "$name*" -and $_.status.phase -eq 'Running' } | Select-Object -First 1
                if ($pod) { $readyCount++ }
            }
            Write-Info "IAM pods Running: $readyCount / $($iamPods.Count)"
            if ($readyCount -eq $iamPods.Count) { $iamReady = $true; break }
        }
        Start-Sleep -Seconds 30
    }
    if (-not $iamReady) {
        Write-Warn 'Not all IAM pods Running yet -- install may still converge'
        & oc get pods -n $Namespace 2>$null
    } else { Write-Pass 'All IAM pods are Running' }

    # STEP 21 - Print cp-console URL and credentials
    Write-Step 'STEP 21 -- cp-console URL and admin credentials'
    $route = & oc get route cp-console -n $Namespace -o jsonpath='{.spec.host}' 2>$null
    if ($route) {
        Write-Pass "cp-console URL: https://$route"
    } else {
        Write-Warn 'cp-console route not yet available -- retry: oc get route -n ibm-common-services'
    }
    Write-Info ''
    Write-Info '--- Initial IAM admin credentials ---'
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $credSecret = & oc get secret platform-auth-idp-credentials -n $Namespace -o name 2>$null
    $ErrorActionPreference = $prev
    if ($credSecret) {
        & oc extract secret/platform-auth-idp-credentials -n $Namespace --to=- 2>$null
    } else {
        Write-Warn 'platform-auth-idp-credentials not yet present -- retry after IAM finishes:'
        Write-Warn "  oc extract secret/platform-auth-idp-credentials -n $Namespace --to=-"
    }
}

# ---------------------------------------------------------------------------
# Post-install verification
# ---------------------------------------------------------------------------
Write-Banner 'Post-Install Verification'

Write-Info '--- CommonService ---'
& oc get commonservice common-service -n $Namespace 2>$null

Write-Info '--- Pods ---'
& oc get pods -n $Namespace -o wide 2>$null

Write-Info '--- OperandRegistry ---'
& oc get operandregistry -n $Namespace 2>$null

Write-Info '--- OperandRequest ---'
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& oc get operandrequest -n $Namespace 2>$null
$ErrorActionPreference = $prev

Write-Info '--- Warning events (last 10) ---'
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$warnEvents = & oc get events -n $Namespace --field-selector type=Warning --sort-by='.lastTimestamp' 2>$null
$ErrorActionPreference = $prev
if ($warnEvents) { $warnEvents | Select-Object -Last 10 | ForEach-Object { Write-Warn $_ } }
else             { Write-Pass 'No Warning events' }

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '+--------------------------------------------------------------+' -ForegroundColor Cyan
Write-Host '|  INSTALL COMPLETE                                            |' -ForegroundColor Green
Write-Host '+--------------------------------------------------------------+' -ForegroundColor Cyan
Write-Host "  Cluster      : $ClusterUrl" -ForegroundColor Cyan
Write-Host "  Namespace    : $Namespace" -ForegroundColor Cyan
Write-Host "  Channel      : $Channel  |  Size: $Size" -ForegroundColor Cyan
Write-Host "  StorageClass : $StorageClass" -ForegroundColor Cyan
if (-not $SkipConsole) {
    $route = & oc get route cp-console -n $Namespace -o jsonpath='{.spec.host}' 2>$null
    if ($route) { Write-Host "  cp-console   : https://$route" -ForegroundColor Green }
}
Write-Host '+--------------------------------------------------------------+' -ForegroundColor Cyan
Write-Host '  Next steps:' -ForegroundColor Cyan
Write-Host '  - Change the default IAM admin password immediately' -ForegroundColor Cyan
Write-Host '  - Set installPlanApproval: Manual for production upgrades' -ForegroundColor Cyan
Write-Host "  - Monitor: oc get pods -n $Namespace -w" -ForegroundColor Cyan
Write-Host '+--------------------------------------------------------------+' -ForegroundColor Cyan
Write-Host ''
