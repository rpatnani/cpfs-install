#!/usr/bin/env node
/**
 * IBM CPFS 4.x Pre-flight Check
 *
 * Verifies the OCP cluster is ready to install IBM Cloud Pak Foundational Services.
 * Outputs a formatted table of PASS/FAIL/WARN results to stdout.
 * Exits with code 1 if any check FAILs; exits 0 if all pass (WARNs are non-blocking).
 *
 * Usage:
 *   node preflight-check.js
 *
 * Requirements:
 *   - Node.js 18+
 *   - oc CLI on PATH and logged in to the target cluster
 */

'use strict';

const { execSync } = require('child_process');

const RESULTS = [];
let hasFail = false;

function run(cmd) {
  try {
    return {
      ok: true,
      output: execSync(cmd, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim()
    };
  } catch (e) {
    return { ok: false, output: (e.stderr || e.message || '').trim() };
  }
}

function check(label, status, detail) {
  RESULTS.push({ label, status, detail });
  if (status === 'FAIL') hasFail = true;
}

// CHECK 1: oc CLI available
const ocVersion = run('oc version --client -o json');
if (ocVersion.ok) {
  try {
    const parsed = JSON.parse(ocVersion.output);
    check('oc CLI available', 'PASS', `client version: ${parsed.clientVersion?.gitVersion || 'unknown'}`);
  } catch {
    check('oc CLI available', 'PASS', 'client detected');
  }
} else {
  check('oc CLI available', 'FAIL', 'oc not found in PATH -- install OpenShift CLI first');
}

// CHECK 2: logged in to a cluster
const whoami = run('oc whoami');
if (whoami.ok) {
  check('Logged in to cluster', 'PASS', `user: ${whoami.output}`);
} else {
  check('Logged in to cluster', 'FAIL', 'Not logged in -- run: oc login <cluster-url>');
}

// CHECK 3: OCP server version >= 4.10
const serverVer = run('oc version -o json');
if (serverVer.ok) {
  try {
    const parsed = JSON.parse(serverVer.output);
    const raw = parsed.openshiftVersion || '';
    const match = raw.match(/^(\d+)\.(\d+)/);
    if (match) {
      const major = parseInt(match[1], 10);
      const minor = parseInt(match[2], 10);
      if (major > 4 || (major === 4 && minor >= 10)) {
        check('OCP version >= 4.10', 'PASS', `server version: ${raw}`);
      } else {
        check('OCP version >= 4.10', 'FAIL',
          `server version ${raw} is below the minimum 4.10 required by CPFS 4.x`);
      }
    } else {
      check('OCP version >= 4.10', 'WARN',
        `Could not parse server version from: "${raw}" -- verify manually`);
    }
  } catch {
    check('OCP version >= 4.10', 'WARN', 'Could not parse oc version JSON -- verify OCP version manually');
  }
} else {
  check('OCP version >= 4.10', 'WARN', 'Could not reach cluster to check server version');
}

// CHECK 4: cluster-admin permission
const canAdmin = run('oc auth can-i "*" "*" --all-namespaces');
if (canAdmin.ok && canAdmin.output.toLowerCase().startsWith('yes')) {
  check('Cluster-admin permission', 'PASS', 'current user has cluster-admin');
} else {
  check('Cluster-admin permission', 'FAIL',
    'Current user does NOT have cluster-admin -- CPFS install requires it');
}

// CHECK 5: default StorageClass with dynamic provisioning
const scResult = run('oc get storageclass -o json');
if (scResult.ok) {
  try {
    const scList = JSON.parse(scResult.output);
    const classes = scList.items || [];
    const defaultSc = classes.find(sc =>
      sc.metadata?.annotations?.['storageclass.kubernetes.io/is-default-class'] === 'true' ||
      sc.metadata?.annotations?.['storageclass.beta.kubernetes.io/is-default-class'] === 'true'
    );
    if (defaultSc) {
      const provisioner = defaultSc.provisioner || 'unknown';
      check('Default StorageClass exists', 'PASS',
        `"${defaultSc.metadata.name}" (provisioner: ${provisioner})`);
    } else {
      const names = classes.map(s => s.metadata?.name).join(', ') || 'none found';
      check('Default StorageClass exists', 'FAIL',
        `No default StorageClass found. Available: [${names}]. ` +
        `Annotate one with storageclass.kubernetes.io/is-default-class=true`);
    }
  } catch {
    check('Default StorageClass exists', 'WARN',
      'Could not parse StorageClass list -- verify manually');
  }
} else {
  check('Default StorageClass exists', 'WARN',
    'Could not retrieve StorageClasses -- verify manually');
}

// CHECK 6: schedulable worker nodes >= 3
const nodesResult = run('oc get nodes -o json');
if (nodesResult.ok) {
  try {
    const nodeList = JSON.parse(nodesResult.output);
    const nodes = nodeList.items || [];
    const schedulable = nodes.filter(n => {
      const isWorker =
        (n.metadata?.labels?.['node-role.kubernetes.io/worker'] !== undefined) ||
        (!n.metadata?.labels?.['node-role.kubernetes.io/master'] &&
         !n.metadata?.labels?.['node-role.kubernetes.io/control-plane']);
      const notUnschedulable = !n.spec?.unschedulable;
      const ready = (n.status?.conditions || []).some(
        c => c.type === 'Ready' && c.status === 'True'
      );
      return isWorker && notUnschedulable && ready;
    });
    if (schedulable.length >= 3) {
      check('Schedulable worker nodes >= 3', 'PASS',
        `${schedulable.length} ready worker node(s) found`);
    } else {
      check('Schedulable worker nodes >= 3', 'FAIL',
        `Only ${schedulable.length} schedulable worker node(s) found -- CPFS needs at least 3`);
    }
  } catch {
    check('Schedulable worker nodes >= 3', 'WARN',
      'Could not parse node list -- verify manually');
  }
} else {
  check('Schedulable worker nodes >= 3', 'WARN',
    'Could not retrieve nodes -- verify manually');
}

// CHECK 7: openshift-marketplace namespace exists
const marketplace = run('oc get namespace openshift-marketplace -o name');
if (marketplace.ok) {
  check('openshift-marketplace namespace', 'PASS', 'present');
} else {
  check('openshift-marketplace namespace', 'FAIL',
    'openshift-marketplace namespace not found -- OLM may not be installed');
}

// CHECK 8: IBM operator catalog pre-existing state
const existingCatalog = run(
  'oc get catalogsource ibm-operator-catalog -n openshift-marketplace ' +
  '-o jsonpath="{.status.connectionState.lastObservedState}"'
);
if (existingCatalog.ok && existingCatalog.output) {
  const state = existingCatalog.output.replace(/^"|"$/g, '');
  if (state === 'READY') {
    check('IBM Operator Catalog (pre-existing)', 'PASS',
      'already present and READY -- Step 13 will be a no-op');
  } else {
    check('IBM Operator Catalog (pre-existing)', 'WARN',
      `already present but state is "${state}" -- may need to be deleted and recreated`);
  }
} else {
  check('IBM Operator Catalog (pre-existing)', 'PASS',
    'not yet installed -- will be created in Step 13');
}

// REPORT
const pad = (s, n) => String(s).padEnd(n);
const width = 70;

console.log('\n' + '-'.repeat(width));
console.log(' IBM CPFS 4.x Pre-flight Check Results');
console.log('-'.repeat(width));
console.log(pad('Check', 40) + pad('Status', 8) + 'Detail');
console.log('-'.repeat(width));

for (const r of RESULTS) {
  const icon = r.status === 'PASS' ? 'PASS' : r.status === 'FAIL' ? 'FAIL' : 'WARN';
  console.log(`[${icon}] ${pad(r.label, 36)} ${r.detail}`);
}

console.log('-'.repeat(width));
if (hasFail) {
  console.log('\n[FAIL] One or more checks FAILED. Fix the issues above before installing CPFS.\n');
  process.exit(1);
} else {
  console.log('\n[PASS] All checks passed. Cluster is ready for CPFS 4.x installation.\n');
  process.exit(0);
}
