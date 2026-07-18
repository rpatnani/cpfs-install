# IBM Cloud Pak Foundational Services (CPFS) 4.x — Automated Installer

> **One script does everything** — NFS storage, IBM CPFS 4.x, cp-console (IAM),
> Keycloak SAML SSO — fully automated, no manual steps required.

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
- [SAML / IDP Configuration](#saml--idp-configuration)
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

# 2. Run the unified script — everything end-to-end in one command
.\cpfs-complete-install.ps1 `
    -ConsoleUrl     'https://console-openshift-console.apps.YOUR-CLUSTER.cp.fyre.ibm.com' `
    -Password       'YOUR-KUBEADMIN-PASSWORD' `
    -EntitlementKey 'YOUR-IBM-ENTITLEMENT-KEY'
```

The script will print the **cp-console URL**, **initial admin credentials**, **Keycloak admin URL**,
and **SAML SSO test credentials** when done.

**Total runtime:** ~35–55 minutes (all 4 phases).

### Want only part of the stack?

```powershell
# CPFS + cp-console only (no SAML/Keycloak)
.\cpfs-complete-install.ps1 -ConsoleUrl '...' -Password '...' -EntitlementKey '...' -SkipSaml

# SAML only — CPFS already installed, just add Keycloak IDP
.\cpfs-complete-install.ps1 -ConsoleUrl '...' -Password '...' -EntitlementKey '...' `
    -SkipStorage -SkipCertManager -SkipConsole

# Re-run (fully idempotent — safe on existing installs)
.\cpfs-complete-install.ps1 -ConsoleUrl '...' -Password '...' -EntitlementKey '...'
```

---

## Parameters

### Core (all required or important)

| Parameter | Default | Description |
|---|---|---|
| `-ConsoleUrl` | *(required)* | OCP web console URL — API URL derived automatically |
| `-Password` | *(required)* | OCP login password |
| `-EntitlementKey` | *(required)* | IBM Entitlement Key from myibm.ibm.com |
| `-ClusterUrl` | *(derived)* | Override API URL (e.g. `https://api.cluster:6443`) |
| `-Username` | `kubeadmin` | OCP login username |

### NFS (Phase 1)

| Parameter | Default | Description |
|---|---|---|
| `-NfsHost` | `master0.<domain>` | OCP node to host NFS exports |
| `-NfsDir` | `/var/data/dynamic` | Export directory on the NFS node |
| `-NfsNamespace` | `managed-nfs-storage` | Namespace for the NFS provisioner |
| `-StorageClass` | `managed-nfs-storage` | StorageClass name to create |

### CPFS (Phase 2–3)

| Parameter | Default | Description |
|---|---|---|
| `-Namespace` | `ibm-common-services` | Namespace for CPFS operator |
| `-Channel` | `v4.6` | OLM subscription channel (`v4.3`, `v4.6`, `v4.9`, `v4.10`) |
| `-Size` | `small` | CommonService size: `starterset`, `small`, `medium`, `large` |

### Keycloak SAML (Phase 4)

| Parameter | Default | Description |
|---|---|---|
| `-RhssoNamespace` | `rhsso` | Namespace for Red Hat SSO (Keycloak) |
| `-RealmName` | `cpfs-realm` | Keycloak realm name |
| `-IdpName` | `keycloak-saml` | CPFS `IdpConfig` CR name |
| `-AdminUser` | `saml-admin` | Test admin username in Keycloak |
| `-AdminPassword` | `Admin1234!` | Test admin password |
| `-ViewerUser` | `saml-viewer` | Test viewer username in Keycloak |
| `-ViewerPassword` | `Viewer1234!` | Test viewer password |

### Skip Flags

| Parameter | Default | Description |
|---|---|---|
| `-SkipStorage` | `false` | Skip Phase 1 (NFS) — use when StorageClass already exists |
| `-SkipCertManager` | `false` | Skip cert-manager install — use when already on cluster |
| `-SkipPreflight` | `false` | Skip pre-flight checks |
| `-SkipConsole` | `false` | Skip Phase 3 — install CPFS only, without cp-console / IAM |
| `-SkipSaml` | `false` | Skip Phase 4 — no Keycloak / SAML configuration |
| `-SkipKeycloak` | `false` | Skip Keycloak install only — still configures CPFS IdpConfig |

---

## What the Script Does (`cpfs-complete-install.ps1`)

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

### Phase 3 — cp-console / IAM Stack (Steps 18–21) {#phase-3}

| Step | Action |
|---|---|
| 18 | Apply `OperandRequest` — triggers ODLM to deploy IAM, CommonUI, PostgreSQL, Management Ingress |
| 19 | Wait for PostgreSQL cluster `Cluster in healthy state` (up to 10 min); auto-reconcile if stuck |
| 20 | Wait for `platform-auth-service`, `platform-identity-*`, `common-web-ui` pods Running (up to 15 min) |
| 21 | Print `cp-console` URL and extract initial IAM admin credentials |

### Phase 4 — Keycloak SAML IDP (Steps 22–34)

| Step | Action |
|---|---|
| 22 | Install `rhsso-operator` via OLM (`redhat-operators`, channel `stable`) |
| 23 | Wait for `rhsso-operator` pod Running |
| 24 | Create Keycloak instance CR; wait for `Ready`; retrieve admin credentials from secret |
| 25 | Create Keycloak Realm (`cpfs-realm`) via `KeycloakRealm` CR |
| 26 | Create SAML Client (`cpfs-sp`) with ACS URL, SLO URL, attribute mappers (email, groups) |
| 27 | Create test users `saml-admin` and `saml-viewer` via Keycloak REST API |
| 28 | Create groups `cpfs-admins` / `cpfs-viewers`; assign users |
| 29 | Fetch Keycloak SAML metadata XML from realm descriptor endpoint (with retry) |
| 30 | Create CPFS `IdpConfig` CR with base64-encoded metadata, `mapIdpGroup: true` |
| 31 | Wait for `IdpConfig` status = `Enabled/Ready` |
| 32 | Apply `ClusterRoleBinding`: `cpfs-admins` → `ClusterAdministrator`, `cpfs-viewers` → `Viewer` |
| 33 | Print final summary: cp-console URL, SSO login URL, Keycloak admin, test credentials |
| 34 | Post-install verification: pods, IdpConfig, Keycloak, events |

---

## Skip Flags

```powershell
# StorageClass already exists
.\cpfs-complete-install.ps1 -SkipStorage ...

# cert-manager already installed
.\cpfs-complete-install.ps1 -SkipCertManager ...

# CPFS + cp-console only (no Keycloak / SAML)
.\cpfs-complete-install.ps1 -SkipSaml ...

# CPFS only — no cp-console, no SAML
.\cpfs-complete-install.ps1 -SkipConsole -SkipSaml ...

# SAML only — CPFS already installed
.\cpfs-complete-install.ps1 -SkipStorage -SkipCertManager -SkipConsole ...

# Re-run (fully idempotent — safe on any existing install)
.\cpfs-complete-install.ps1 ...
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

## SAML / IDP Configuration

After running `install-cpfs-end-to-end.ps1`, run the companion script to configure
**Keycloak (Red Hat SSO)** as a SAML Identity Provider for cp-console:

```powershell
.\configure-idp-saml.ps1 `
    -ConsoleUrl 'https://console-openshift-console.apps.YOUR-CLUSTER.cp.fyre.ibm.com' `
    -Password   'YOUR-KUBEADMIN-PASSWORD'
```

### What the SAML script does (13 steps)

| Step | Action |
|---|---|
| 1 | Login to OCP cluster |
| 2 | Install Red Hat SSO (Keycloak) operator via OLM (`redhat-operators`) |
| 3 | Wait for `rhsso-operator` pod Running |
| 4 | Create Keycloak instance CR; wait for `Ready`; retrieve admin credentials |
| 5 | Create Keycloak Realm (`cpfs-realm`) |
| 6 | Create SAML Client in the realm (CPFS as Service Provider) with ACS URL, attribute mappers |
| 7 | Create test users `saml-admin` and `saml-viewer` with passwords |
| 8 | Create groups `cpfs-admins` / `cpfs-viewers` and assign users |
| 9 | Fetch Keycloak SAML metadata XML from its descriptor endpoint |
| 10 | Create CPFS `IdpConfig` CR with the metadata (base64-encoded) |
| 11 | Wait for `IdpConfig` to become Ready |
| 12 | Create `ClusterRoleBinding` to map `cpfs-admins` → `ClusterAdministrator`, `cpfs-viewers` → `Viewer` |
| 13 | Print SSO login URL, Keycloak admin URL, test credentials, and verification commands |

### SAML script parameters

| Parameter | Default | Description |
|---|---|---|
| `-ConsoleUrl` | *(required)* | OCP web console URL |
| `-Password` | *(required)* | OCP kubeadmin password |
| `-CpConsoleUrl` | *(derived)* | cp-console route URL (derived from ConsoleUrl) |
| `-Namespace` | `ibm-common-services` | CPFS namespace |
| `-RhssoNamespace` | `rhsso` | Namespace for Red Hat SSO |
| `-RealmName` | `cpfs-realm` | Keycloak realm name |
| `-IdpName` | `keycloak-saml` | CPFS `IdpConfig` CR name |
| `-AdminUser` | `saml-admin` | Test admin username in Keycloak |
| `-AdminPassword` | `Admin1234!` | Test admin password |
| `-ViewerUser` | `saml-viewer` | Test viewer username in Keycloak |
| `-ViewerPassword` | `Viewer1234!` | Test viewer password |
| `-SkipKeycloak` | `false` | Skip Keycloak install (Steps 2–8) — use when Keycloak is already running |

### SAML architecture

```
Browser
  └─► cp-console (platform-auth-service)
            │  SAML AuthnRequest
            ▼
      Keycloak (rhsso namespace)
            │  realm: cpfs-realm
            │  client: cpfs-sp (SAML)
            │  users: saml-admin, saml-viewer
            │  SAML Response (signed)
            ▼
      platform-auth-service validates assertion
            │  maps email NameID → CPFS user
            ▼
      cp-console dashboard (logged in via SSO)
```

---

## Files in This Repository

```
cpfs-install/
├── README.md                      # This file
├── CHANGELOG.md                   # Version history
├── cpfs-complete-install.ps1      # UNIFIED script — all 4 phases, 34 steps (USE THIS)
├── install-cpfs-end-to-end.ps1    # Phase 1-3 only (NFS + CPFS + cp-console)
├── configure-idp-saml.ps1         # Phase 4 only (Keycloak + SAML)
└── preflight-check.js             # Pre-flight check script (Node.js, 8 checks)
```

> **Use `cpfs-complete-install.ps1`** for all new installs.
> The individual scripts (`install-cpfs-end-to-end.ps1`, `configure-idp-saml.ps1`)
> are retained for reference and for running specific phases independently.

---

## References

- [IBM CPFS 4.x Documentation](https://www.ibm.com/docs/en/cloud-paks/foundational-services/4.x)
- [nfs-subdir-external-provisioner](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner)
- [OpenShift cert-manager Operator](https://docs.openshift.com/container-platform/latest/security/cert_manager_operator/index.html)
- [OpenShift CLI (oc) Download](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/)
- [IBM Entitlement Key](https://myibm.ibm.com/products-services/containerlibrary)
