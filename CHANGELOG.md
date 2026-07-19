# Changelog

All notable changes to this project will be documented in this file.

---

## [5.0.0] — 2026-07-18

### Changed — Aligned to csramapatnani2026 cluster architecture (11 fixes)

#### Fix 1-3 — Parameter defaults updated
- `-Namespace` default: `ibm-common-services` → **`ibm-operators`**
- `-Channel` default: `v4.6` → **`v4.19`**
- `-Size` default: `small` → **`medium`**
- `-RhssoNamespace` default: `rhsso` → **`ibm-operators`**

#### Fix 4 — CommonService CR fields
- Added `license.accept: true` (required by CPFS v4.19+)
- Added `operatorNamespace: ibm-operators`
- Added `servicesNamespace: ibm-operators`
- Added `ibm-zen-operator` to services list

#### Fix 5 — IBM cert-manager replaces Red Hat cert-manager
- Step 9 now installs `ibm-cert-manager-operator` from `ibm-cert-manager-catalog` (channel `v4.2`)
  in namespace `ibm-cert-manager` instead of `openshift-cert-manager-operator` from `redhat-operators`
- Step 10 now waits for pods in `ibm-cert-manager` namespace

#### Fix 6 — IBM Zen operator added (Steps 15b)
- New step 15b: installs `ibm-zen-operator` Subscription (channel `v6.10`) from `ibm-operator-catalog`
- Required for zen-core, zen-audit, zen-minio, zen-watcher pods on your cluster

#### Fix 7 — ibm-pg-operator added (Step 15c)
- New step 15c: creates `ibm-pg-operator-catalog` CatalogSource + `ibm-pg-operator` Subscription (channel `v28`)
- Required for EDB PostgreSQL cluster used by Keycloak (`keycloak-edb-cluster`)

#### Fix 8 — RHBK operator replaces rhsso-operator (Step 22)
- Step 22 now subscribes to `rhbk-operator` from `redhat-operators` channel `stable-v24`
  instead of `rhsso-operator` channel `stable`
- OperatorGroup creation skipped when deploying into `ibm-operators` (already has one)

#### Fix 9 — Keycloak CR updated to RHBK spec (Step 24)
- API version: `keycloak.org/v1alpha1` → **`k8s.keycloak.org/v2alpha1`**
- Name: `keycloak` → **`cs-keycloak`** (matches your cluster)
- Spec: removed `postgresDeploymentSpec`; added EDB backend (`keycloak-edb-cluster-rw`),
  TLS secret, hostname, proxy headers, token-exchange feature flags (matching your cluster)
- Instances: 1 → 2

#### Fix 10 — Keycloak admin secret updated (Step 24)
- Secret name: `credential-keycloak` → **`cs-keycloak-initial-admin`** (RHBK pattern)
- Secret key: `ADMIN_PASSWORD` → `password` / `username` (RHBK key names)

#### Fix 11 — SAML ACS URL corrected (Step 26)
- ACS URL: `/ibm/saml20/callback` → **`/ibm/saml20/defaultSP`**
  (matches the `saml-ui-callback` route present on your cluster)

---

## [4.0.0] — 2026-07-18

### Added — Unified single script
- **`cpfs-complete-install.ps1`** — merges `install-cpfs-end-to-end.ps1` and
  `configure-idp-saml.ps1` into a **single 34-step, 4-phase script** that does everything
  in one command: NFS → CPFS → cp-console → Keycloak SAML SSO
- **Phase 4** (Steps 22–34) fully integrated into the unified script:
  Keycloak install, realm, SAML client, test users, groups, IdpConfig CR, role bindings, final summary
- **New skip flags:** `-SkipSaml` (skip entire Phase 4), `-SkipKeycloak` (skip Keycloak install only)
- **Final summary banner** (Step 33): prints cp-console URL, SSO login URL, Keycloak admin URL,
  and test user credentials in one consolidated block
- **Post-install verification** (Step 34): runs automatically — pods, IdpConfig, Keycloak, events
- **README updated:** new unified Quick Start, expanded parameter reference table split by phase,
  Phase 4 step table, updated Files section marking `cpfs-complete-install.ps1` as the primary script

### Retained (for reference / single-phase use)
- `install-cpfs-end-to-end.ps1` — Phase 1–3 (NFS + CPFS + cp-console), 21 steps
- `configure-idp-saml.ps1` — Phase 4 (Keycloak + SAML), 13 steps

---

## [3.0.0] — 2026-07-18

### Added — SAML / IDP configuration script
- **`configure-idp-saml.ps1`** — 13-step automated script that configures Keycloak (Red Hat SSO)
  as a SAML 2.0 Identity Provider for IBM CPFS 4.x cp-console
- **Step 2:** Installs `rhsso-operator` via OLM subscription from `redhat-operators` catalog
- **Step 4:** Creates Keycloak instance CR; waits for `Ready`; retrieves admin credentials
  from `credential-keycloak` secret automatically
- **Step 5:** Creates a `KeycloakRealm` CR (`cpfs-realm`) with brute-force protection
- **Step 6:** Creates a `KeycloakClient` SAML SP (`cpfs-sp`) with ACS URL, SLO URL,
  email/firstName/lastName/groups attribute mappers, and redirect URIs
- **Step 7:** Creates test users `saml-admin` and `saml-viewer` with passwords via Keycloak REST API
- **Step 8:** Creates groups `cpfs-admins` / `cpfs-viewers` and assigns users
- **Step 9:** Fetches Keycloak SAML metadata XML from the realm descriptor endpoint (with retry loop)
- **Step 10:** Creates CPFS `IdpConfig` CR with base64-encoded metadata, `nameIdFormat: email`,
  `mapIdpGroup: true`, `groupsAttribute: groups`
- **Step 11:** Waits for `IdpConfig` status to become `Enabled/Ready`
- **Step 12:** Creates `ClusterRoleBinding` mappings:
  `cpfs-admins` → `icp:cloudpak:administrator`, `cpfs-viewers` → `icp:cloudpak:viewer`
- **Step 13:** Prints SSO login URL, Keycloak admin console URL, test credentials,
  and all verification commands

### Added — New script parameters
- `-RhssoNamespace` — Keycloak namespace (default: `rhsso`)
- `-RealmName` — Keycloak realm name (default: `cpfs-realm`)
- `-IdpName` — CPFS IdpConfig CR name (default: `keycloak-saml`)
- `-AdminUser` / `-AdminPassword` — test admin credentials
- `-ViewerUser` / `-ViewerPassword` — test viewer credentials
- `-SkipKeycloak` — skip Steps 2–8 when Keycloak is already running

### Added — README section
- New `## SAML / IDP Configuration` section with quick start, parameter reference,
  13-step table, and SAML architecture diagram
- Updated `## Files in This Repository` to include `configure-idp-saml.ps1`

---

## [2.0.0] — 2026-07-18

### Added — Phase 3: cp-console (IAM Stack)
- **Step 9–10:** Automated install of Red Hat `openshift-cert-manager-operator` from `redhat-operators`
  catalog — this is a required prerequisite that was missing from v1.0.0.
  Without cert-manager, the PostgreSQL operator cannot create `cs-ca-certificate-secret` and stays
  stuck in `Unable to create required cluster objects` indefinitely.
- **Step 18:** `OperandRequest` applied with full IAM stack:
  `ibm-im-operator`, `ibm-im-mongodb-operator`, `ibm-idp-config-ui-operator`,
  `ibm-management-ingress-operator`, `ibm-ingress-nginx-operator`, `ibm-licensing-operator`,
  `ibm-cert-manager-operator`, `common-service-postgresql`
- **Step 19:** Wait for EDB PostgreSQL cluster `common-service-db` to reach `Cluster in healthy state`.
  Auto-annotates the cluster CR to force reconcile if stuck on the CA secret timing race.
- **Step 20:** Wait for all four IAM pods Running:
  `platform-auth-service`, `platform-identity-management`, `platform-identity-provider`, `common-web-ui`
- **Step 21:** Prints the `cp-console` URL and extracts `platform-auth-idp-credentials` admin credentials.

### Added — New skip flags
- `-SkipCertManager` — bypass cert-manager install when already present
- `-SkipConsole` — install CPFS only, without deploying cp-console / IAM

### Changed
- Step numbering updated from 15 to 21 steps across 3 phases
- Summary banner now prints cp-console URL in green when available
- Post-install verification now shows CommonService, OperandRequest, and pods in one block
- CPFS idempotency check no longer exits the script — continues to Phase 3 if CPFS is already installed

### Fixed
- PostgreSQL timing race: if `cs-ca-certificate-secret` doesn't exist at first reconcile,
  the script now waits for cert-manager to create it and then triggers a reconcile annotation

---

## [1.0.0] — 2026-07-17

### Added
- `install-cpfs-end-to-end.ps1` — 15-step automated installer for IBM CPFS 4.x on OCP/Fyre
- `preflight-check.js` — Node.js pre-flight checker with 8 cluster readiness checks
- `README.md` — documentation with quick start, parameter reference, troubleshooting

### Phase 1 — NFS StorageClass
- SSH-free NFS setup via `oc debug node` + `nsenter` (no external SSH required)
- Automatic discovery of NFS node internal IP from OCP node object
- NFS dir defaulted to `/var/data/dynamic` (RHCOS root `/` is a read-only composefs)
- PVC smoke test validates storage before proceeding
- `oc annotate` used to set default StorageClass (avoids PowerShell JSON quoting issues)

### Phase 2 — IBM CPFS 4.x
- IBM Operator CatalogSource with 45-min registry poll
- OLM Subscription on configurable channel (default `v4.6`)
- CommonService CR with IAM, Licensing, CertManager operands
- Polling waits with timeouts and diagnostic output on failure
- `$ErrorActionPreference` scoped around `oc debug` calls to prevent stderr noise from halting execution
- All `Where-Object` results wrapped in `@()` to prevent `.Count` failure on null pipeline
