# Release preparation checklist

This checklist prepares reviewable evidence. It does not authorize publication. Main-branch
pushes are not version releases. Contract 1.3, SDK 1.3.0 and current host profiles are separate
identifiers; see [version rules](versioning.md) and [change history](../CHANGELOG.md).

## Evidence before requesting publication

- [ ] Record exact full reviewed commits for the shared package and both hosts. Fetch each
  repository and verify clean `main`; incorporate hardware-side successors under the workspace
  collaboration rules, with regression tests after any rebase. Never rewrite published history.
- [ ] Both host locks name the same full shared commit and their managed dependency checks
  confirm that revision and a clean cache. No adjacent uncommitted source is compiled.
- [ ] Verify successful remote CI on all three exact release candidate commits, including
  shared macOS/Linux and host-specific required lanes. Save run URLs and commit IDs; an older
  green run does not validate a newer commit.
- [ ] Run all four unchanged protocol fixtures through both process-local host runners.
  Compare all 40/65/83/97 steps and every normalized semantic field; retain mappings,
  per-step results, fixture SHA-256 and exact host/shared revisions. Explain entropy-only
  differences separately; private-engine atomicity and injected-clock checks belong here.
- [ ] Run SDK 1.3.0's explicit contract 1.0/1.1/1.2/1.3 host-behavior matrix and preserve all
  existing SDK assertions. Verify unsupported features fail in the client before sending.
- [ ] Run frozen SDK 1.1.0 and 1.2.0 probes against each current host. Record actual discovery
  rejection when their allowlists reject 1.3. This proves the version gate, **not** a successful
  old-client round trip. Do not alter old SDK bytes or advertise a false host version. Resolve
  any release criterion demanding a successful round trip with an explicit reviewed decision.
- [ ] Regenerate tool schemas and typed examples and compare byte-for-byte with their published
  sources; validate schemas, examples, fixtures and live report schema.
- [ ] Build immutable deliveries from clean candidate commits under the unified delivery root.
  Check directory ownership, atomic publication and index de-duplication under the common
  lock. Verify every INDEX entry against its manifest's version/profile/full commit fields.
- [ ] Independently recompute the SHA-256 of each root `manifest.json`, each listed delivery
  file, every copied shared source, and each SDK zip member. Compare root manifest hashes
  with INDEX and the consumer's out-of-band pins. Ensure `source_dirty` is false.
- [ ] Run the packaged live checker from outside each source tree, with the packaged fixture,
  SDK and truthful host role map. Save both reports outside the immutable delivery. Compare
  normalized step status, actual dispositions/errors and explicit skip reasons. A step that
  needs an unavailable clock, capacity, role or private state is skipped, never counted as
  passed; no unknown transport outcome is replayed.
- [ ] Verify generic deliveries contain only intended public artifacts. Private principal
  registries, bearer tokens and fingerprints are absent from manifests, archives and reports.
- [ ] Verify the consumer's fixed contract/SDK/profile/mapping/full revisions and manifest
  hashes match the intended released artifacts. The consumer supplies actual end-to-end
  Worker/Mock evidence and stop/expiry/isolation results; supplier fixture success is not a
  substitute. Record unresolved consumer acceptance gaps.
- [ ] Write the exact proposed tags, release descriptions, release attachment filenames and
  hashes, target repositories and target full commits for review. Proposed tag syntax is
  `v<major>.<minor>.<patch>` per repository (for example `v1.3.0`); the software release version
  is not automatically the wire contract version. Check that each name is unused and that
  no tag will be moved or overwritten.

## Publication requires the user's authorization for this release

- [ ] All workspace publication prerequisites are satisfied: exact three-repository CI green,
  both hosts adopted contract 1.3 and rebuilt deliveries, and the consumer's full integration
  is accepted. Prepare the evidence above **before** requesting approval.
- [ ] Obtain the user's current explicit authorization for the exact repositories, commits,
  tag names, tag pushes, GitHub Releases and attachments. Prior permission to push `main`
  does not authorize any of these actions. If authorization is absent, stop at preparation.
- [ ] Only after that authorization, create the reviewed tags. Tag creation itself needs it;
  an unpublished local tag is still outside this preparation task.
- [ ] Only after that authorization, push those exact tags (shared package before hosts),
  without force or unrelated tags; independently verify each remote tag's target commit.
- [ ] Only after that authorization, create the reviewed Releases and upload the exact
  verified delivery attachments. Download and hash the published assets to confirm identity.
- [ ] Record release URLs, tag targets, asset hashes and authorized consumer pin updates in
  delivery records. Do not silently rewrite a consumer repository or its fixed version.
