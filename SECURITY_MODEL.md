# RalphOS Security Model

**Status:** Draft (SSOT for security architecture decisions)  
**Last Updated:** 2026-02-14

RalphOS is an agents-only, headless appliance intended to run `ralphd` plus
isolated execution sandboxes, with a **security-tight-by-default** stance.
High-level product goals live in `RalphOS/planning.md`. This document makes the
security model explicit and end-to-end.

## 0) Invariants (Non-Negotiables)

These are the "this must always be true" rules RalphOS is designed around:

- **Immutable base OS**: A/B system slots; no in-place mutation of the running `/`.
- **Durable state lives under `/var`** (or an explicit data partition); system slots are read-only at runtime.
- **Agents do not run on the host by default**: untrusted workloads run inside sandboxes.
- **Default deny**:
  - no sandbox egress unless policy allows it
  - no secrets exposed to a sandbox unless policy allows it
  - no host filesystem mounts unless policy allows them
- **Capability-based access**: jobs request capabilities; policy grants; everything is audited.
- **Credentials via tool-native login flows**: RalphOS does not implement a generic "paste your API key here" UI.

## 1) Goals

### 1.1 Primary Security Goals

- **Host integrity**: a sandbox escape must not be able to persistently modify the base OS.
- **Multi-team isolation**: one team/job cannot read/modify another team’s data and secrets by default.
- **Controlled network access**: allow internet access only when needed, with allowlists and audit visibility.
- **Secrets minimization**: scope secrets tightly; prefer short-lived tokens; deny by default.
- **Auditability**: enough telemetry to reconstruct "who did what" without recording secret material.
- **Safe updates**: offline composition of the next slot, trial boot, commit/rollback.

### 1.2 Security Constraints That Enable "Power-User" Agent Work

RalphOS must support "coding genius" and build workloads (compilers, package
managers, registries, CI-like tasks) **without** giving those workloads host-level
privileges. The model is:

- put developer toolchains in **sandbox images**, not on the host rootfs
- grant broad capabilities only by explicit policy, per job/team, with audit

## 2) Non-Goals (v0)

- **Perfect exfiltration prevention** once a sandbox is granted egress and secrets.
  - Mitigation is least-privilege, time-bounded secret leases, allowlists, and audit.
- **A generic secret-manager UX** (vault UI) for arbitrary third-party keys.
  - Operators use tool-native flows (`claude --login`, `codex --login`, etc.).
- **Chat gateway connectors** (WhatsApp/Telegram/etc.) (per `RalphOS/planning.md`).

## 3) Threat Model

### 3.1 Adversaries / Failure Modes

- **Malicious code under test**: untrusted repositories, dependencies, build scripts.
- **Prompt injection**: untrusted text attempting to manipulate tool use.
- **Tool compromise**: third-party CLIs (Codex/Claude Code/Gemini/etc.) are not trusted.
- **Remote attacker**: attempts to exploit the northbound API.
- **Policy mistakes**: overly broad allowlists, secret exposure, overly powerful roles.
- **Supply chain compromise**: package sources, recipe changes, update payloads.

### 3.2 Assets

- Tenant/team **source code**, knowledge bases, work artifacts.
- **Credentials** produced by tool-native login flows.
- **Host base OS** integrity and boot selection state.
- **Audit logs** (must be trustworthy enough to support forensics).

### 3.3 Security Boundaries

Primary boundaries:

- **Host vs sandbox** (primary isolation wall).
- **Tenant/team vs tenant/team** (isolation of data, network, secrets).

Secondary boundaries:

- **Northbound API** vs local-only privileged operations.
- **Update composition** (offline slot build) vs runtime slot execution.

## 4) System Overview (Trusted Computing Base)

### 4.1 Host Components (TCB)

The host TCB should remain small:

- `ralphd` control plane (policy engine + orchestrator)
- sandbox runtime / microVM manager
- `recab` (A/B slot selection, commit/rollback)
- `recipe` (package composition into a target sysroot, not the live root)
- minimal diagnostics tooling (enough for provisioning + incident response)

Everything else (dev toolchains, build tools, LLM CLIs) should prefer **sandbox images**.

### 4.2 Northbound API

- One API for the companion client (Ralph4Days).
- Default binding is **localhost**; remote mode is explicit and hardened.

## 5) Identity, Authentication, Authorization

### 5.1 Identities (First-Class Concepts)

- **Operator**: host administrator (physical console / provisioned access).
- **Tenant**: an org boundary (optional for single-org deployments).
- **Team**: the operational boundary for code/secrets in a single-org deployment.
- **User**: a human identity (companion client).
- **Agent**: a logical identity ("who" is doing work).
- **Job**: a task invocation (the unit of policy and audit).
- **Sandbox**: the execution instance for a job.

### 5.2 Authentication (Proposed v0)

- **Provisioning**: injected SSH key (as documented in `docs/content/.../04-variants.ts`).
- **Remote northbound API**:
  - mTLS is preferred for "appliance" posture.
  - Token-based auth is acceptable only with short lifetimes and rotation.
- **Local-only mode** remains the default.

### 5.3 Authorization: Capability Model (Core)

RalphOS should avoid "global root-like permissions" for agents. Instead:

- A job requests a set of **capabilities**.
- The policy engine decides allow/deny with an explicit reason.
- Capabilities are scoped:
  - to a tenant/team
  - to a duration (lease)
  - to a sandbox instance
  - to an egress allowlist and specific mounts

Examples of capabilities (names illustrative):

- `fs:volume:<tenant>/<team>/<volume>:ro|rw`
- `net:egress:<profile>` (default-deny unless granted)
- `creds:tool:<toolname>:use` (mount tool credential blob)
- `recipe:compose-slot` (compose inactive slot; never mutate live `/`)
- `host:reboot` (operator-only)

High-risk capability requests should support a policy mode like:

- `require_operator_approval = true`

## 6) Sandboxing Model (The Core Security Feature)

### 6.1 Primary Boundary: microVM per Job (Preferred)

RalphOS is intended to use a VM/microVM boundary as the primary wall (per
`RalphOS/planning.md`). The security model assumes:

- one sandbox per job (or per agent) as the default
- each sandbox has:
  - separate filesystem (read-only base + per-job writable overlay)
  - resource quotas (CPU, RAM, disk, pids, open files)
  - explicit network policy (default deny egress)
  - explicit mounts only (no host filesystem passthrough)

**Fallback**: containers may be used when microVM is unavailable, but must be an
explicit policy choice that marks the job as **reduced isolation**.

### 6.2 Filesystem Model

- Sandbox root filesystem is a **read-only image**.
- Job workspace storage is provided by **volumes** stored under `/var` on the host:
  - `/var/lib/ralphd/volumes/<tenant>/<team>/<volume>/...`
- Volumes are only mounted when policy grants them.
- Default mount options for data volumes: `nodev,nosuid,noexec`.
  - Allowing `exec` must be explicit (needed for compilers/build tools in workspaces).

### 6.3 Process Model

- Sandboxes run as unprivileged identities from the host perspective.
- No "agent spawns arbitrary host processes" path:
  - all host-side effects must go through `ralphd` (and thus through policy + audit).

### 6.4 Resource Limits

- CPU, memory, pids, open files, disk quotas enforced per sandbox.
- Kill-on-timeout and kill-on-policy-revoke must exist as primitives.

## 7) Network Model

### 7.1 Host Networking

- No listening services by default beyond what is required for provisioning.
- Northbound API exposure is explicit and hardened.

### 7.2 Sandbox Networking (Default-Deny)

- Each sandbox gets an isolated network namespace or VM network.
- Egress is **blocked by default**.
- When policy grants egress, it should be allowlisted by:
  - destination domains (preferred, enforced via a controlled DNS proxy), and/or
  - destination IP ranges + ports + protocols (enforced via host firewall)

### 7.3 Egress Logging

Every sandbox connection attempt should be attributable:

- `tenant/team/job/sandbox` identity
- destination (ip/port/proto)
- best-effort domain attribution (via controlled DNS)
- bytes in/out and timing

This is required for "run a company" auditability.

## 8) Secrets & Credentials

### 8.1 Principles

- Secrets are **not ambient**.
- Secrets are **scoped** and **time-bounded**.
- Secret material must never be written into the audit log.

### 8.2 Storage (Opaque Blobs)

RalphOS should treat tool credentials as opaque, tool-owned blobs:

- Operators authenticate using the tool’s own login flow (e.g. `claude --login`).
- The resulting credential state is stored under root-owned paths, for example:
  - `/var/lib/ralphd/credentials/<tenant>/<tool>/...`
- `ralphd` should not parse or interpret these credentials; it only controls access.

### 8.3 Injection

Preferred injection modes:

- tmpfs file mounts at `/run/secrets/...` with strict permissions
- read-only mounts of tool credential directories when tools require a fixed path

## 9) Recipe + Build Security (Dev Tools Without Host Privilege)

### 9.1 Host OS Updates

RalphOS is immutable-only. Updates are "compose the next slot", not "mutate `/`":

- Use `recipe --sysroot <inactive-slot-mount>` to compose the next system.
- Validate offline.
- Trial boot.
- Commit/rollback via `recab`.

Relevant repo specs:

- `tools/recipe/OS_UPGRADES_BRAINDUMP.md`
- `tools/recipe/REQUIREMENTS.md` (sysroot + security requirements)
- `tools/recab/REQUIREMENTS.md` (commit/rollback semantics)

### 9.2 Sandbox Images (Where Dev Toolchains Live)

Dev toolchains should be shipped as sandbox images (or layers) that are built
and updated via `recipe` in an isolated build environment.

Security requirements:

- downloads should be hashed and verified (SHA-256+)
- prefer HTTPS; never disable TLS validation
- reject unsafe URL schemes like `file://` (per recipe requirements)
- builds should run in a build sandbox with minimal privileges

### 9.3 LLM-Assisted Recipe Refresh (Gated)

When an LLM helps update recipes (URLs/checksums/deps), treat all fetched web
content as untrusted input:

- record provenance (sources consulted, diffs, checksum changes)
- require explicit approval for system recipes and shared images
- prefer lock files and content hashes for reproducibility

## 10) Updates, Rollback, and Boot Integrity

- A/B try/commit semantics are required (see `tools/recab/REQUIREMENTS.md`).
- Trial boot must run a minimal health check before committing:
  - `ralphd` starts
  - policy loads
  - sandbox can be created and can run a trivial command

Roadmap (not assumed in v0 unless implemented):

- signed update manifests
- dm-verity for system slots
- Secure Boot / measured boot

## 11) Audit

### 11.1 What Must Be Recorded

- API calls (who/what/when), including auth context
- policy decisions (request, allow/deny, reason)
- sandbox lifecycle and configuration:
  - image id
  - mounts granted
  - network policy granted
  - resource limits
- tool invocations (command + args, with redaction rules)
- secret leases (which secret, scope, expiry; never the secret value)
- egress events
- update operations (compose, set-next, trial boot, commit, rollback)

### 11.2 Tamper Evidence (Proposed)

- append-only audit log with hash chaining
- optional remote log shipping for durability

## 12) Operations: Provisioning, Break-Glass, Incident Response

### 12.1 Provisioning

- SSH public key injection for initial access (preferred).
- Password auth disabled by default (`sshd`: no password login).
- Operators can disable SSH after initial provisioning (appliance posture).

Recommended shape (so recovery does not require shipping a universal password):

1. Store provisioned SSH public keys on the persistent state partition under:
   - `/var/lib/ralphd/provision/ssh/authorized_keys.d/*.pub`
2. A host unit applies them at boot into the chosen admin account’s `authorized_keys`.
3. Key rotation is done by updating files under `/var` and rebooting (or reloading).

### 12.2 Break-Glass

- Break-glass should require **console / out-of-band access** (hypervisor console, BMC serial-over-LAN, physical console).
- Break-glass must be **audited** (who/when/why) and should leave a clear marker in `/var/log`.

If SSH keys are lost:

1. Use console/out-of-band access to boot a recovery target (or a minimal rescue environment).
2. Mount the persistent state partition (`/var`).
3. Drop a new public key into `/var/lib/ralphd/provision/ssh/authorized_keys.d/`.
4. Reboot; the provisioning unit re-applies keys.

Root password guidance:

- Do not ship a default root password.
- If a root password exists at all, treat it as **console-only** (never accepted over SSH).

### 12.3 Incident Response Primitives

Required operator actions:

- revoke a team/job’s egress
- revoke secret leases
- stop/kill sandboxes
- snapshot volumes for forensics
- roll back to previous slot

## 13) Open Questions (To Resolve in RalphOS v0)

- microVM choice and implementation (firecracker vs qemu microvm vs something else)
- multi-tenant vs single-org with teams as the primary boundary
- encryption at rest for `/var` (volumes + credentials)
- northbound API auth pairing model with Ralph4Days
- host LSM posture (Landlock-only vs enabling AppArmor/SELinux)
