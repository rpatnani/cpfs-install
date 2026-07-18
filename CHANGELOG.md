# Changelog

All notable changes to this project will be documented in this file.

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
