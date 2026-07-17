# Changelog

All notable changes to this project will be documented in this file.

---

## [1.0.0] — 2026-07-17

### Added
- `install-cpfs-end-to-end.ps1` — end-to-end automated installer for IBM CPFS 4.x on OCP/Fyre
- `preflight-check.js` — Node.js pre-flight checker with 8 cluster readiness checks
- `README.md` — full documentation with quick start, parameter reference, troubleshooting

### Phase 1 — NFS StorageClass
- SSH-free NFS setup via `oc debug node` + `nsenter` (no external SSH required)
- Automatic discovery of NFS node internal IP from OCP node object
- RBAC, StorageClass, and Deployment applied inline from upstream YAMLs
- PVC smoke test to validate storage before proceeding
- StorageClass annotated as cluster default

### Phase 2 — IBM CPFS 4.x
- IBM Operator CatalogSource with 45-min registry poll
- OperatorGroup + OLM Subscription on configurable channel (default `v4.6`)
- CommonService CR with explicit IAM, Licensing, and CertManager operands
- Polling waits with timeouts and diagnostic output on failure
- Idempotent — detects existing installation and exits cleanly

### Engineering notes
- Works on RHCOS nodes where `/` is a read-only composefs; NFS dir defaults to `/var/data/dynamic`
- `$ErrorActionPreference` scoped around `oc debug` calls to prevent stderr noise from halting execution
- All `Where-Object` results wrapped in `@()` to prevent `.Count` failure on null pipeline results
- `oc annotate` used instead of `oc patch --type=merge` to avoid PowerShell JSON quoting issues
