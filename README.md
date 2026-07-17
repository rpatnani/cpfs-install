# IBM Cloud Pak Foundational Services (CPFS) 4.x — Automated Installer

> One PowerShell script that provisions NFS storage **and** installs IBM CPFS 4.x
> on an OpenShift (OCP) cluster running on IBM Fyre — fully automated, no manual steps.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Parameters](#parameters)
- [What the Script Does](#what-the-script-does)
  - [Phase 1 — NFS StorageClass](#phase-1--nfs-storageclass)
  - [Phase 2 — IBM CPFS 4.x](#phase-2--ibm-cpfs-4x)
- [Skip Flags](#skip-flags)
- [Post-Install Verification](#post-install-verification)
- [Troubleshooting](#troubleshooting)
- [Files in This Repository](#files-in-this-repository)
- [References](#references)

---

## Overview

This project automates the full installation of
[IBM Cloud Pak Foundational Services 4.x](https://www.ibm.com/docs/en/cloud-paks/foundational-services/4.x)
on an OCP / Fyre cluster, including the NFS StorageClass that CPFS requires.

**What gets installed:**

| Component | Details |
|---|---|
| NFS StorageClass | `nfs-subdir-external-provisioner` on `master0`, set as cluster default |
| IBM Operator Catalog | `icr.io/cpopen/ibm-operator-catalog:latest` |
| CPFS Operator | `ibm-common-service-operator` via OLM subscription |
| IAM Operator | `ibm-iam-operator` |
| Licensing Operator | `ibm-licensing-operator` |
| Cert Manager Operator | `ibm-cert-manager-operator` |

---

## Architecture

```
Windows Workstation (PowerShell)
        |
        |  oc login / oc debug / oc apply
        v
OCP Cluster (Fyre)
  ├── master0  <-- NFS server (exports /var/data/dynamic)
  ├── openshift-marketplace
  │     └── ibm-operator-catalog pod
  └── ibm-common-services
        ├── ibm-common-service-operator
        ├── operand-deployment-lifecycle-manager
        ├── ibm-iam-operator
        ├── ibm-licensing-operator
        └── ibm-cert-manager-operator
```

---

## Prerequisites

| Requirement | Minimum | Notes |
|---|---|---|
| Windows PowerShell | 5.1+ | Included in Windows 10/11 |
| `oc` CLI | 4.10+ | Auto-downloaded by the setup instructions below |
| Node.js | 18+ | Required for `preflight-check.js` |
| OCP cluster | 4.10+ | Must have cluster-admin access |
| IBM Entitlement Key | — | From [myibm.ibm.com](https://myibm.ibm.com/products-services/containerlibrary) |
| Internet access | — | To pull `icr.io/cpopen/ibm-operator-catalog` |

### Install the oc CLI (Windows, one-time)

```powershell
# Download and extract oc.exe to your user profile
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
git clone https://github.com/YOUR-ORG/cpfs-install.git
cd cpfs-install

# 2. Run the installer (supply your own values)
.\install-cpfs-end-to-end.ps1 `
    -ConsoleUrl    'https://console-openshift-console.apps.YOUR-CLUSTER.cp.fyre.ibm.com' `
    -Password      'YOUR-KUBEADMIN-PASSWORD' `
    -EntitlementKey 'YOUR-IBM-ENTITLEMENT-KEY'
```

The script will:
1. Log in to the cluster
2. Set up NFS storage on `master0` (no SSH required — uses `oc debug node`)
3. Deploy the NFS provisioner and smoke-test a PVC
4. Run pre-flight checks
5. Install IBM CPFS 4.x end-to-end
6. Print IAM admin credentials when ready

**Total runtime:** ~15–25 minutes depending on image pull speed.

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
| `-Size` | `small` | CommonService size profile (`starterset`, `small`, `medium`, `large`) |
| `-SkipStorage` | `false` | Skip Phase 1 — use when a StorageClass already exists |
| `-SkipPreflight` | `false` | Skip the pre-flight check step |

---

## What the Script Does

### Phase 1 — NFS StorageClass

| Step | Action |
|---|---|
| 1 | Login to OCP cluster |
| 2 | Check if a StorageClass already exists (skip if so) |
| 3 | SSH-free NFS setup via `oc debug node` + `nsenter` on `master0` |
| 4 | Discover NFS server internal IP from OCP node object |
| 5 | Download and apply RBAC, StorageClass, Deployment YAMLs from upstream |
| 6 | Wait for NFS provisioner pod → Running (up to 3 min) |
| 7 | Smoke-test: create a PVC, verify Bound, delete it |
| 8 | Annotate StorageClass as cluster default |

> **Why `oc debug node` instead of SSH?**
> RHCOS master nodes use a composefs read-only root filesystem. `nsenter -a -t 1` enters
> the host's writable mount namespace (`/var`) without needing SSH access from outside the cluster.

### Phase 2 — IBM CPFS 4.x

| Step | Action |
|---|---|
| 9  | Pre-flight checks (8 checks — see `preflight-check.js`) |
| 10 | Idempotency check — exits cleanly if CPFS already installed |
| 11 | Create `ibm-common-services` namespace |
| 12 | Create `ibm-entitlement-key` pull secret in `cp.icr.io` |
| 13 | Apply `ibm-operator-catalog` CatalogSource; wait for pod Ready (up to 5 min) |
| 14 | Apply OperatorGroup + Subscription; wait for CSV Succeeded (up to 10 min) |
| 15 | Apply CommonService CR; wait for phase = Succeeded (up to 20 min) |

---

## Skip Flags

```powershell
# StorageClass already exists — skip NFS setup entirely
.\install-cpfs-end-to-end.ps1 -SkipStorage ...

# Cluster already validated — skip pre-flight checks
.\install-cpfs-end-to-end.ps1 -SkipPreflight ...

# Both — jump straight to CPFS install
.\install-cpfs-end-to-end.ps1 -SkipStorage -SkipPreflight ...
```

The script is **idempotent** — running it again on an already-installed cluster exits cleanly at Step 10.

---

## Post-Install Verification

After the script completes, verify the installation:

```bash
# All pods running
oc get pods -n ibm-common-services

# CommonService phase
oc get commonservice common-service -n ibm-common-services

# Operand registries
oc get operandregistry -n ibm-common-services
oc get operandconfig  -n ibm-common-services

# IAM console route
oc get route -n ibm-common-services | grep cp-console

# Retrieve initial IAM admin credentials
oc extract secret/platform-auth-idp-credentials -n ibm-common-services --to=-
```

> **Important:** Change the default `admin` password immediately after first login.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `mkdir: cannot create directory '/data': Read-only file system` | RHCOS root fs is read-only | Use `-NfsDir /var/data/dynamic` (default) |
| `Pre-flight checks failed: No default StorageClass` | Phase 1 was skipped or failed | Run without `-SkipStorage`, or: `oc annotate storageclass <name> storageclass.kubernetes.io/is-default-class=true --overwrite` |
| CSV stuck in `Installing` | Image pull slow or entitlement key wrong | Check `oc get installplan -n ibm-common-services` and `oc describe pod` for ImagePullBackOff |
| CommonService stuck in `Updating` | ODLM still deploying operands | Wait — can take up to 20 min. Check: `oc logs -n ibm-common-services -l app.kubernetes.io/name=operand-deployment-lifecycle-manager` |
| `platform-auth-idp-credentials` secret not found | IAM not yet initialised | Wait ~5 min after CommonService Succeeded, then retry |
| NFS PVC stuck in `Pending` | NFS server not reachable from pods | Verify firewall rules allow pods to reach the master0 `10.x.x.x` IP on port 2049 |

---

## Files in This Repository

```
cpfs-install/
├── README.md                      # This file
├── CHANGELOG.md                   # Version history
├── install-cpfs-end-to-end.ps1    # Main install script (PowerShell)
└── preflight-check.js             # Pre-flight check script (Node.js)
```

---

## References

- [IBM CPFS 4.x Documentation](https://www.ibm.com/docs/en/cloud-paks/foundational-services/4.x)
- [nfs-subdir-external-provisioner](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner)
- [OpenShift CLI (oc) Download](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/)
- [IBM Entitlement Key](https://myibm.ibm.com/products-services/containerlibrary)
