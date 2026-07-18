# IBM Cloud Pak Foundational Services (CPFS) 4.x — Automated Installer

> One PowerShell script that provisions NFS storage, installs IBM CPFS 4.x, and
> deploys **cp-console** (IAM) — fully automated, no manual steps required.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Parameters](#parameters)
- [What the Script Does](#what-the-script-does)
- [Skip Flags](#skip-flags)
- [Post-Install Verification](#post-install-verification)
- [Troubleshooting](#troubleshooting)
- [Files in This Repository](#files-in-this-repository)
- [References](#references)

---

## Overview

This project automates the **complete** installation of
[IBM Cloud Pak Foundational Services 4.x](https://www.ibm.com/docs/en/cloud-paks/foundational-services/4.x)
on an OCP / Fyre cluster — from bare cluster to a working **cp-console login page** in one command.

**What gets installed end-to-end:**

| Component | Details |
|---|---|
| NFS StorageClass | `nfs-subdir-external-provisioner` on `master0`, set as cluster default |
| Red Hat cert-manager | `openshift-cert-manager-operator` v1 — required by PostgreSQL and IAM |
| IBM Operator Catalog | `icr.io/cpopen/ibm-operator-catalog:latest` |
| CPFS Operator | `ibm-common-service-operator` via OLM subscription |
| ODLM | `operand-deployment-lifecycle-manager` |
| PostgreSQL | `common-service-db` (EDB Postgres for Kubernetes) |
| IAM Operator | `ibm-im-operator` |
| CommonUI Operator | `ibm-idp-config-ui-operator` |
| Management Ingress | `ibm-management-ingress-operator` |
| **cp-console** | `common-web-ui` + `platform-auth-service` + `platform-identity-*` |

---

## Architecture

```
Windows Workstation (PowerShell 5.1+)
        |
        |  oc login / oc debug / oc apply
        v
OCP Cluster (Fyre / RHCOS)
  ├── cert-manager-operator namespace
  │     ├── cert-manager-operator pod
  │     └── cert-manager / cainjector / webhook pods
  │
  ├── managed-nfs-storage namespace
  │     └── nfs-client-provisioner pod
  │
  ├── master0  <-- NFS server (/var/data/dynamic exported)
  │
  └── ibm-common-services namespace
        ├── ibm-common-service-operator
        ├── operand-deployment-lifecycle-manager
        ├── common-service-db-1 / -2  (PostgreSQL)
        ├── common-web-ui             --> cp-console route
        ├── platform-auth-service
        ├── platform-identity-management
        └── platform-identity-provider
```

---

## Prerequisites

| Requirement | Minimum | Notes |
|---|---|---|
| Windows PowerShell | 5.1+ | Included in Windows 10/11 |
| `oc` CLI | 4.10+ | See install instructions below |
| Node.js | 18+ | For `preflight-check.js` |
| OCP cluster | 4.10+ | Must have cluster-admin |
| IBM Entitlement Key | — | From [myibm.ibm.com](https://myibm.ibm.com/products-services/containerlibrary) |
| Internet access | — | Pulls from `icr.io`, `cp.icr.io`, `registry.redhat.io` |

### Install the oc CLI (Windows, one-time)

```powershell
Invoke-WebRequest -Uri "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-windows.zip" `
    -OutFile "$env:TEMP\oc.zip" -UseBasicParsing
Expand-Archive -Path "$env:TEMP\oc.zip" -DestinationPath "$env:USERPROFILE\.local\bin" -Force
$env:PATH = "$env:USERPROFILE\.local\bin;$env:PATH"
oc version --client
```

---

## Quick Start

```powershell
# 1. Clone this repository
git clone https://github.com/rpatnani/cpfs-install.git
cd cpfs-install

# 2. Run — everything is automated
.\install-cpfs-end-to-end.ps1 `
    -ConsoleUrl     'https://console-openshift-console.apps.YOUR-CLUSTER.cp.fyre.ibm.com' `
    -Password       'YOUR-KUBEADMIN-PASSWORD' `
    -EntitlementKey 'YOUR-IBM-ENTITLEMENT-KEY'
```

The script will print the **cp-console URL** and **initial admin credentials** when done.

**Total runtime:** ~25–40 minutes.

---

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `-ConsoleUrl` | *(required)* | OCP web console URL — API URL derived automatically |
| `-ClusterUrl` | *(derived)* | Override API URL (e.g. `https://api.cluster:6443`) |
| `-Username` | `kubeadmin` | OCP login username |
| `-Password` | *(required)* | OCP login password |
| `-EntitlementKey` | *(required)* | IBM Entitlement Key from myibm.ibm.com |
| `-NfsHost` | `master0.<domain>` | OCP node to host NFS exports |
| `-NfsDir` | `/var/data/dynamic` | Export directory on the NFS node |
| `-NfsNamespace` | `managed-nfs-storage` | Namespace for the NFS provisioner |
| `-StorageClass` | `managed-nfs-storage` | StorageClass name to create |
| `-Namespace` | `ibm-common-services` | Namespace for CPFS operator |
| `-Channel` | `v4.6` | OLM subscription channel (`v4.3`, `v4.6`, `v4.9`, `v4.10`) |
| `-Size` | `small` | CommonService size: `starterset`, `small`, `medium`, `large` |
| `-SkipStorage` | `false` | Skip Phase 1 (NFS) — use when StorageClass already exists |
| `-SkipCertManager` | `false` | Skip cert-manager install — use when already on cluster |
| `-SkipPreflight` | `false` | Skip pre-flight checks |
| `-SkipConsole` | `false` | Skip Phase 3 — install CPFS only, without cp-console / IAM |

---

## What the Script Does

### Phase 1 — NFS StorageClass (Steps 1–8)

| Step | Action |
|---|---|
| 1 | Login to OCP cluster |
| 2 | Check if StorageClass already exists (skip if so) |
| 3 | Configure NFS exports on `master0` via `oc debug node` + `nsenter` (no SSH) |
| 4 | Discover NFS server internal IP from OCP node object |
| 5 | Apply RBAC, StorageClass, Deployment from upstream nfs-subdir-external-provisioner |
| 6 | Wait for NFS provisioner pod Running (up to 3 min) |
| 7 | Smoke-test: create PVC, verify Bound, delete |
| 8 | Annotate StorageClass as cluster default |

> **Why `oc debug node` instead of SSH?**  
> RHCOS master nodes use a composefs read-only root. `nsenter -a -t 1` enters the writable
> host mount namespace without needing SSH access from outside the cluster.

### Phase 2 — IBM CPFS 4.x (Steps 9–17)

| Step | Action |
|---|---|
| 9  | Install Red Hat `cert-manager` operator from `redhat-operators` catalog |
| 10 | Wait for `cert-manager`, `cainjector`, `webhook` pods Running (up to 5 min) |
| 11 | Pre-flight checks (8 checks — see `preflight-check.js`) |
| 12 | Idempotency check — skip CPFS install if already present |
| 13 | Create `ibm-common-services` namespace |
| 14 | Create `ibm-entitlement-key` pull secret |
| 15 | Apply `ibm-operator-catalog` CatalogSource; wait for pod Ready (up to 5 min) |
| 16 | Apply OperatorGroup + Subscription; wait for CSV Succeeded (up to 10 min) |
| 17 | Apply CommonService CR; wait for phase = Succeeded (up to 20 min) |

> **Why cert-manager first?**  
> CPFS v4.6 uses PostgreSQL for IAM. The PostgreSQL operator requires `cs-ca-certificate-secret`
> which is generated by the cert-manager `Issuer` CRD. Without cert-manager installed first,
> the PostgreSQL cluster CR stays in `Unable to create required cluster objects` indefinitely.

### Phase 3 — cp-console / IAM Stack (Steps 18–21)

| Step | Action |
|---|---|
| 18 | Apply `OperandRequest` — triggers ODLM to deploy IAM, CommonUI, PostgreSQL, Management Ingress |
| 19 | Wait for PostgreSQL cluster `Cluster in healthy state` (up to 10 min); auto-reconcile if stuck |
| 20 | Wait for `platform-auth-service`, `platform-identity-*`, `common-web-ui` pods Running (up to 15 min) |
| 21 | Print `cp-console` URL and extract initial IAM admin credentials |

---

## Skip Flags

```powershell
# StorageClass already exists
.\install-cpfs-end-to-end.ps1 -SkipStorage ...

# cert-manager already installed
.\install-cpfs-end-to-end.ps1 -SkipCertManager ...

# CPFS only — no cp-console / IAM
.\install-cpfs-end-to-end.ps1 -SkipConsole ...

# Re-run (idempotent) — safe to run again on existing install
.\install-cpfs-end-to-end.ps1 ...
```

---

## Post-Install Verification

After the script completes, verify:

```bash
# 1. All pods Running
oc get pods -n ibm-common-services

# 2. CommonService Succeeded
oc get commonservice common-service -n ibm-common-services

# 3. PostgreSQL healthy
oc get cluster -n ibm-common-services

# 4. OperandRequest Running
oc get operandrequest -n ibm-common-services

# 5. cp-console route
oc get route cp-console -n ibm-common-services

# 6. IAM admin credentials
oc extract secret/platform-auth-idp-credentials -n ibm-common-services --to=-
```

**Expected cp-console URL format:**
```
https://cp-console-ibm-common-services.apps.<cluster-domain>
```

> **Important:** Change the default `admin` password immediately after first login.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `mkdir: cannot create '/data'` | RHCOS root is read-only | Default NFS dir is `/var/data/dynamic` — already fixed |
| Pre-flight: No default StorageClass | Phase 1 skipped or failed | Run without `-SkipStorage`, or annotate manually |
| CSV stuck in `Installing` | Image pull slow / entitlement key wrong | Check `oc get installplan -n ibm-common-services` |
| PostgreSQL: `Unable to create cluster objects` | cert-manager not installed | Run without `-SkipCertManager`; script installs it automatically |
| PostgreSQL cluster stuck after cert-manager install | Timing race | Script auto-annotates cluster to trigger reconcile |
| IAM pods in `CrashLoopBackOff` | PostgreSQL not yet Ready | Wait — pods recover once DB is healthy |
| `platform-auth-idp-credentials` not found | IAM still initialising | Wait ~5 min after all pods are Running, then retry |
| cp-console: certificate error in browser | Self-signed cert on Fyre | Click "Proceed anyway" or add cluster CA to browser trust |

---

## Files in This Repository

```
cpfs-install/
├── README.md                      # This file
├── CHANGELOG.md                   # Version history
├── install-cpfs-end-to-end.ps1    # Main install script (PowerShell, 21 steps, 3 phases)
└── preflight-check.js             # Pre-flight check script (Node.js, 8 checks)
```

---

## References

- [IBM CPFS 4.x Documentation](https://www.ibm.com/docs/en/cloud-paks/foundational-services/4.x)
- [nfs-subdir-external-provisioner](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner)
- [OpenShift cert-manager Operator](https://docs.openshift.com/container-platform/latest/security/cert_manager_operator/index.html)
- [OpenShift CLI (oc) Download](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/)
- [IBM Entitlement Key](https://myibm.ibm.com/products-services/containerlibrary)
