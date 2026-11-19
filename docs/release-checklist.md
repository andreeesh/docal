# Docal release-readiness checklist

This is the acceptance procedure for the next Docal release after `0.3.0`.
It is **not** a release announcement and does not imply that a new tag
exists. The current repository may contain features not represented by
the last published `VERSION` or Git tag.

## Scope and evidence

- ZIP + SQL import is merged: protected new-site creation, input staging,
  serialized URL normalization, local WordPress admin and DB validation.
- SSH pull is merged: deliberate alias/path, remote read-only acquisition
  through WP-CLI/rsync, local import, no live remote changes made by Docal.
- Safe Start is merged: ephemeral WordPress file copy, plugin/MU-plugin
  exclusion, outbound IPv4/IPv6/DNS preflight, loopback-only HTTPS,
  temporary MySQL data/socket volumes and source-DB integrity guard.
- These flows have been exercised on WSL2 with Docker Engine, including
  synthetic fixtures and an authorized read-only remote import for SSH.
- Mailpit is merged: loopback-only shared inbox, PHP `mail()` transport for
  newly generated images, an opt-in reversible MU-plugin for existing sites,
  and operational checks for Docker networking, HTTP API and internal SMTP.
- Safe Start remains isolated from `docal-proxy` and keeps PHP mail blocked
  with `sendmail_path=/bin/false`.

## Automatic gates

- [ ] `main` is protected against force pushes and deletion; changes
  enter through pull requests with the required CI jobs.
- [ ] The active `main` ruleset requires `tests` and `shell-checks`; both
  pass on the **exact release SHA**, not only the previous PR head.
- [ ] The Publish Docal Release workflow additionally requires
  `mailpit-docker` to pass on that exact SHA before it can create a tag.
- [ ] Python source files under `scripts/` parse without writing
  `__pycache__` into user worktrees.
- [ ] All `tests/*.sh` pass, including source DB isolation and
  Docker name-collision refusals.
- [ ] Every relative README/docs Markdown link resolves to a real file.
- [ ] `git diff --check` has no whitespace errors.

## Manual WSL2 Docker acceptance (synthetic only)

- [ ] Use a disposable synthetic WordPress ZIP + SQL fixture with a
  globally unique Docal slug. Never reuse real customer QA installations.
- [ ] Record original container IDs, network memberships (including
  peers), volume IDs, image inventory, Docal config hashes **and mtimes**
  before running any Docal CLI or other tools that could change state.
- [ ] Confirm importer refuses a pre-existing site and global Docker
  resource name collision without modifying anything already present.
- [ ] Confirm importer leaves WordPress stopped and new DB healthy;
  normal `docal start` is not used for initial inspection.
- [ ] Preview is localhost HTTPS only. Safe PHP and safe-db join only
  private internal network, and safe-web has no direct published port.
- [ ] External IPv4, IPv6 and DNS are blocked both in egress preflight
  and in an in-container PHP test. Uploaded PHP execution is denied.
- [ ] Ensure the original MySQL container is already healthy **before**
  safe start. Safe Start must not issue any `docker compose up db`,
  restart, network-connect or other source-container reconciliation.
- [ ] Observe source DB ID, state, mount fingerprint, config and all
  network memberships **before, during and after** safe start.
- [ ] Source/clone table names, counts, representative rows and metadata
  match before browsing; authenticated admin modifications appear **only**
  in the temporary MySQL clone; source DB canonical hash stays unchanged.
- [ ] Run safe stop and verify removal of only temporary file copy,
  containers, networks, MySQL data and socket volumes. Re-run safely.
- [ ] Verify Docker object inventories and Docal config hash/metadata
  equal initial baseline; avoid reading config through mutating CLI paths.
- [ ] Record browser certificate trust separately from valid SAN/expiry.
- [ ] On a synthetic WordPress site, verify Mailpit start/status/stop,
  loopback HTTP only, private SMTP, API capture, MU-plugin enable/disable
  and failure diagnostics. Use synthetic content and `.test` recipients.
- [ ] Confirm Safe Start does not join `docal-proxy`, cannot reach Mailpit,
  retains `sendmail_path=/bin/false` and leaves its source database intact.

## Packaging and publication

- [ ] Review remaining limitations: older images without `msmtp-mta` do not
  support standalone PHP `mail()` via Mailpit; custom plugins or PHP can
  bypass capture; themes still execute PHP; source remote files/DB are not
  atomic snapshots; historical external links may remain; and local CA
  trust can vary by browser.
- [ ] Confirm current user-facing docs describe merged features as available
  and distinguish planned CLI capabilities from separate Desktop work. Do
  not claim `.wpress` E2E if not validated. The `CHANGELOG.md` roadmap under
  0.2.0 records what was planned at that historical release; it is not the
  current roadmap.
- [ ] Select release version intentionally: `0.4.0` includes Mailpit and
  its operational checks; `v0.3.0` is already published and must not be
  retagged or overwritten.
- [ ] Update `VERSION` and changelog version heading in a reviewed PR.
- [ ] Merge release changes via the protected `main` branch; check CI on
  the resulting merge/squash SHA.
- [ ] In GitHub Actions, manually run **Publish Docal Release** from
  `main` with version `0.4.0`. The workflow checks `VERSION`, the exact
  `main` SHA, `tests`, `shell-checks` and `mailpit-docker` before creating
  an **annotated** `v0.4.0` tag and publishing
  `docs/releases/v0.4.0.md` as a GitHub Release.
  Confirm the resulting tag points to the approved release commit.
  If a manual publication fails, inspect its log before retrying; do not
  replace an existing tag without a separate review.
- [ ] Test the documented installation/update path in a disposable
  fresh WSL2 environment; do not overwrite existing Docal user sites.

## Out of scope for v0.4.0

Database snapshots, source auto-detection and incremental SSH
synchronization remain future features. The Safe Start MySQL clone is
disposable; it is **not** a durable backup/snapshot feature.
