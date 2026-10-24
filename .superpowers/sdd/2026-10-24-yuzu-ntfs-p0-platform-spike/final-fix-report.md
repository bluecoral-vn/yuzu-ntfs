# Final fix report — base 1b91297

## Verdict

**Incomplete acceptance: G1's exhaustive handler × every-branch reply-once coverage is not implemented. Do not resume mounted writes.** The behavioral safety changes below are implemented, with the evidence and TDD limitations explicitly distinguished. No upstream file was edited, no ABI member was reordered, and no push, mount, attachment, installation, disk-management probe or notarization was performed. The requested Debug app build includes its existing ad-hoc build phase; it was not installed. T7-R1, T7-R4 and T7-R5 remain binding. F-R1/F-R2 were supplied by Main during this fix wave.

Commands below ran from `Packages/NTFSCore` unless a repository-root command is shown. `swift test --filter NAME` denotes the exact focused invocation, not a hypothetical check. Full plain suite: 17 probe/policy + 12 glue + 25 bridge tests passed; all fixture-entry comparisons retained.

## Per finding

### E1 — reserved metadata mutation policy

Changes: `engine.c`, `internal.c`, `ntfs_bridge.h`, `Module/YuzuNTFSVolume.swift`. Records <24 and direct $Extend children are marked NB_READ_ONLY and rejected by buffered write/truncate/setattr/remove/rename (including replacement target), write blockmap and write completion. Creation/rename into reserved directories is denied; the root remains a valid namespace parent. The module inhibits KOIO and write-open for the new flag. Reads remain supported.

Regression: `reservedMetadataCannotBeMutated`; routing: `p0ResidencyRoutingAndWriteSafety`.

- RED: `swift test --filter reservedMetadataCannotBeMutated` (artifact 452): write/truncate/complete/setattr returned 0 rather than EPERM; blockmap returned ENOSPC after destructive setup; writeCount 12 versus 2. Six issues on a disposable image.
- GREEN: same command (454): `Test run with 1 test in 1 suite passed`.
- Routing RED: `swift test --filter p0ResidencyRoutingAndWriteSafety` (456): NB_READ_ONLY (16) was not inhibited/write-denied, three issues. GREEN same command (458), one test passed.
- Scope of regression: directly exercises $Bitmap data/size/time/map/completion and zero device-write delta. Namespace policy and $Extend classification are implemented but do not have separate new fault regressions in this wave.

### E2 — unsafe sparse materialization publication

Resolution is **F-R1 policy cutover**, not a writer-gate implementation. Already-sparse files reject writes, size changes, write blockmaps and completions with EPERM. `e2_prepare` and `e2_finish` independently guard sparse inodes. The old sparse materialization code remains unreachable through authorized P0 operations. P1 design: detached TT lcnalloc allocation → zero + flush → runlist insertion/mapping-pair publication. Documented in `ntfs_bridge.h`, `PATCHES.md`, `p0-r3-throughput.md`.

Regression: `sparseMutationsAreRejectedWithoutDeviceWrites` in BridgeConformanceTests; fixture-only `nb_e2_test_sparse_fixture` constructs sparse on-disk state without bypassing subsequent write guards.

- RED `swift test --filter sparseMutationsAreRejectedWithoutDeviceWrites` (473): writes, truncate, blockmap, completion and size setattr succeeded; count 1 instead of 0; writeCount 27 rather than 16. Eight issues including the resulting size/read mismatch.
- GREEN `swift test --filter 'failedCreatePromotionRollsBackNamespace|failedMappingAllocationNeverPublishesEOF|sparseMutationsAreRejectedWithoutDeviceWrites'` (488): all three tests passed.
- Module routing RED `swift test --filter p0ResidencyRoutingAndWriteSafety` (475): sparse flag 8 was writable/not inhibited, four issues. GREEN observed for that routing test in 477; the same run exposed a fixture-setup interaction, subsequently corrected with the dedicated sparse constructor.

F-R2 additional regression: `ordinaryGrowthKeepsNonSparseAllocationAndSupportsLaterKOIO`. TT's default truncate marks grown ordinary files sparse, which would have made common ftruncate/preallocation usage immutable under F-R1. `tt_core_ntfs_attrib.c` now includes pristine upstream and exposes private HOLES_NO allocation. `e2_resize` uses it for ordinary growth; both truncate and setattr(size) call it. Mapping preallocates with the old EOF and target allocation size. VDL remains unchanged. Real allocation means the non-sparse T5-R2 gap-zero path cannot preserve sparse holes.

- RED `swift test --filter ordinaryGrowthKeepsNonSparseAllocationAndSupportsLaterKOIO` (480): sparse flag set, alloc_size 0 < size 65536, later write mapping EPERM.
- GREEN same command (482): passed after 0.009 s; checks 64 KiB zeros, later payload at 4096, real allocation and remounted zero edges.

### E3 — terminal free-space initialization failure

Changes: integration wrapper `tt_core_ntfs_super.c`, `internal.c`, `engine.c`, private test header. The wrapper substitutes the sole free-space work callback through INIT_WORK. It calls pristine upstream, detects a producer that exits without FreeClusterKnown, stores terminal -ENOMEM/free-count, sets errors/read-only, marks known and wakes all waiters. Mount joins initialization before publishing the volume and returns the terminal error; consequently no exposed statfs/allocation request can wait on an exited producer. The hook faults the actual file_ra_state kzalloc in that worker.

Regression `freeSpaceInitializationFailureTerminatesMount`:

- RED `swift test --filter freeSpaceInitializationFailureTerminatesMount` (490): result 0 rather than ENOMEM, nonnil published volume, two issues. This first run installed the fault request but predated the wrapper consuming it; it did not deliberately hang the uncorrected core.
- GREEN same command (492): one test passed after 0.008 s, ENOMEM and nil volume within the bound. Core error/dirty diagnostics are expected and visible.

### E4 — named-stream lifetime and attributes

Changes `engine.c`: synthetic stream holds retain base inodes, stream reads/getattr resolve held stream identities, getattr preserves stream ref/size and NB_READ_ONLY. ADS remains buffered and mutations remain ENOTSUP.

Regression `streamPublicationLifetimeAndAttributes` (lookup → hold → getattr → read → release):

- RED `swift test --filter streamPublicationLifetimeAndAttributes` (460): hold EINVAL, getattr ENOTSUP, wrong ref/size/flags, release ENOENT; six issues.
- GREEN same command: one test passed after 0.001 s. The existing complete ntfscat ADS comparison also remains in the full suite.

### E5 — failed raw-write cache invalidation

Changes `engine.c`, `internal.c`: failed raw write completions invalidate the entire affected cached range, preserve original I/O status and never invoke size advancement; successful completion retains flush/VDL ordering.

Regression `failedRawWriteInvalidatesCachedPrefixWithoutChangingSize` primes an unaligned cached read, physically overwrites only a prefix of a mapped range, reports EIO, then checks buffered new bytes and unchanged size.

- RED `swift test --filter failedRawWriteInvalidatesCachedPrefixWithoutChangingSize` (463): cached old bytes [60,91,…] rather than thirteen 167s, one issue.
- GREEN same command: one test passed after 0.004 s.

### E6 — rollback failed create promotion

Changes `engine.c`: promotion/getattr failure after creation removes the newly published entry; rollback failure forces read-only/EIO.

Regression `failedCreatePromotionRollsBackNamespace`:

- Instrumented RED `swift test --filter failedCreatePromotionRollsBackNamespace` (486): injected promotion ENOMEM was returned, but lookup still returned 0 instead of ENOENT, one issue.
- GREEN combined transactional command (488): passed.

### E7 — remove fallible EOF restoration

Changes `tt_core_ntfs_attrib.c`, `internal.c`, `engine.c`: map allocation calls private expansion with unchanged data_size and preallocation target (HOLES_NO). There is no expand-EOF-then-restore step. `NB_E2_FAIL_AFTER_ALLOCATION` injects ENOMEM after successful physical allocation without changing EOF.

Regression `failedMappingAllocationNeverPublishesEOF` checks immediate size, zero returned mappings, and persisted size after remount.

- RED `swift test --filter 'failedCreatePromotionRollsBackNamespace|failedMappingAllocationNeverPublishesEOF'` (484): mapping returned 0 rather than injected ENOMEM and count 1 rather than 0.
- GREEN combined transactional command (488): passed, immediate and persisted EOF 0.
- **TDD limitation:** F-R2 had already replaced size publication before this focused fault test was added. This RED proves the fault hook/error/no-mapping contract, not a replay of the original fallible-restore enlarged-EOF bug. No stronger RED evidence is claimed.

### E8 — secondary sparse rollback failure

**Moot under Main's F-R1 ruling.** P0 rejects sparse writes before materialization; the retained materialization/rollback code cannot be entered through the bridge. The fixture constructor only invokes TT truncate to prepare a sparse inode; it does not bypass authorization for prepare/finish and cannot exercise rollback. No double-fault test is claimed. Restoring sparse writes in P1 requires the ordered detached-allocation design and its interruption/rollback tests first.

### F1 — effective read-only routing

Changes `YuzuNTFSVolume.swift`: current statfs state is checked/latches read-only before write-open, write blockmap and resident KOIO eligibility. Error querying state also fails closed. Existing mappings cannot be revoked by this ABI: their completions still receive a reply and bridge errors; sizes do not advance after EROFS. Documentation states this limit rather than claiming physical write revocation.

Regression `effectiveReadOnlyRejectsWriteOpenAndInhibitsResidentPublication` uses actual handlers with injected bridge state and ReplyOnce:

- RED `swift test --filter effectiveReadOnlyRejectsWriteOpenAndInhibitsResidentPublication` (500): open replied success instead of EROFS; resident attributes advertised KOIO, two issues.
- GREEN same command (502): one test passed.
- Already-issued mapping/completion terminal paths are not exhaustively reply-once tested (see G1).

### F2 — legacy reclaim identity/pin

Changes `YuzuNTFSVolume.swift`: macOS 26 legacy reclaim retains the weak identity and pin until deinitialization; macOS 27 keeps SDK tryReclaim-controlled release.

Regression `staleLegacyReclaimPreservesRepublishedIdentityAndPin`:

- RED `swift test --filter staleLegacyReclaimPreservesRepublishedIdentityAndPin` (466): different live item after stale reclaim; release count 1 instead of 0, two issues.
- GREEN same command (468): one test passed; pin releases at actual deinit.

### F3 — bounded benchmark supervisor

Changes `scripts/bench.sh`, new `scripts/bench_supervisor.py`: supervising parent has no mounted-file I/O, owns total deadline, handles SIGINT/SIGTERM, revokes before signaling only its worker process group, never blocks reaping/tearing down after timeout and reports surviving PID/PGID/possible attachment. Authorization is granted in the child only after supervisor setup. Existing normal teardown runs within the parent's total deadline.

Regression `test_supervisor_deadline_revokes_before_terminating_worker`; repository-root `python3 scripts/test-bench.py` → three tests OK. Simulated child only sleeps; no mount/attach/disk commands run.

**TDD limitation:** this supervisor regression was added after the supervisor implementation; no RED run is claimed. Explicit SIGTERM delivery and an uninterruptible kernel-U child were not exercised. Signal handling is implemented, not end-to-end mounted verified.

### F4 — balanced activation/teardown ownership

Changes append-only `nb_dispose` in `ntfs_bridge.h` and engine implementation. A dedicated callback lock drains resource callbacks, sets no-I/O teardown, then releases core state with subsequent resource reads/writes refused and flush callbacks suppressed. Ordinary unmount remains sync/unmount. The Swift device is strongly owned through teardown; activation root-publication failure disposes, deactivate disposes activated-but-never-mounted state, and deinit is a final ownership backstop. Duplicate activation returns EBUSY.

Regressions:

- `disposePerformsNoDeviceWrites`: RED `swift test --filter disposePerformsNoDeviceWrites` (510), writeCount 9 vs 2. GREEN in command `swift test --filter 'activationCancellationAndRootPublicationFailureBalanceEngine|disposePerformsNoDeviceWrites'` (512): dispose passed. Expected core writeback-refusal diagnostics remain visible; no device write callback is invoked.
- `activationCancellationAndRootPublicationFailureBalanceEngine`: RED same combined command (512), close count 0 instead of 1 in both paths. GREEN `swift test --filter activationCancellationAndRootPublicationFailureBalanceEngine` (514): passed; both paths assert exactly one handler reply.
- The new device protocol and injected initializer support headless real-handler tests; the production initializer still derives writable permission from allowlist/device admission.

### F5 — initial attributes create transaction

Changes `YuzuNTFSVolume.swift`: reject oversized initial size before create, increment directory verifier on successful namespace creation, roll back failed publication/initial-attribute preparation, invalidate again after successful rollback, retain invalidation and return EIO on failed rollback.

Regression `initialAttributeFailureRollsBackCreatedEntryAndInvalidatesVerifier`:

- RED `swift test --filter initialAttributeFailureRollsBackCreatedEntryAndInvalidatesVerifier` (506): orphan remained, remove count 0, parent version 1; three issues.
- GREEN same command (508): passed; reply exactly once.

### F6 — requested vs actual filesystem identity

Changes `scripts/bench.sh`: boot signature must match selected NTFS/exFAT driver before authorization; after mount diskutil plist must match expected backing node, FilesystemType and MountPoint before any workload. Tests execute only preflight code or the isolated mount function with subprocess doubles; no disk commands run.

- RED repository-root `python3 scripts/test-bench.py` (preflight-only run): `SystemExit not raised`; mismatch incorrectly reached authorization.
- GREEN after preflight change: one test OK. Final `python3 scripts/test-bench.py`: three tests OK, including wrong backing node and wrong actual filesystem rejection.
- **TDD limitation:** actual-mounted-identity regression was added after that check; no RED is claimed for that half. Real mounted identity was not exercised on the wedged host.

### F7 — destructive helper opens

Changes `tools/seqio`: write open omits O_TRUNC and includes O_NOFOLLOW/O_NONBLOCK; fstat must show S_IFREG before ftruncate. Read mode remains separate. O_NONBLOCK prevents a FIFO open from blocking before its descriptor-type check.

- RED repository-root `python3 scripts/test-seqio.py`: two failures, write to symlink and /dev/null incorrectly returned 0.
- GREEN same command: two tests OK (also included final root script test command). The symlink target retains original bytes. No disk node was opened; /dev/null was the harmless nonregular-device stand-in.

### F8 — current status documentation

`README.md` no longer claims loading ENOTSUP or deferred C engine. It describes actual engine/RO/RW serial policy, warns experimental/not production safe, links R3 incident and keeps R1/R2 as history. Documentation-only; no behavioral RED test applicable.

### G1 — handler × path reply-once coverage

**Not complete.** `HandlerTests.swift` provides a shared ReplyOnce assertion, injectable bridge vtable/device access and tests actual FSKit handlers. It does not cover every handler or every branch. Runtime-created FSTaskOptions instances are only unused sentinels because the SDK exposes no public initializer; no options method is invoked.

| Handler | Path exercised by ReplyOnce | Remaining coverage |
|---|---|---|
| activate | root-publication success; root hold failure | mount failure; duplicate activation; root-ref/pin variations |
| deactivate | activated without mount | already-unmounted/empty; teardown failure semantics |
| openItem | write after effective remount-RO → EROFS | read success; write success; inhibited flags; getattr/query failure |
| getAttributes | resident after effective remount-RO → inhibited | ordinary success; getattr error; every file kind |
| createItem | initial size ENOSPC → rollback | success, bad type, bad name, prevalidation, create/pin/rollback failure |
| mount | not covered | success |
| unmount | not covered | active/empty |
| synchronize | not covered | success/error |
| reclaimItem | legacy policy unit regression, not ReplyOnce handler | macOS 27 success/refusal; legacy handler reply |
| closeItem | not covered | success |
| lookupItem(named:) | not covered | success/name/lookup/hold error |
| setAttributes | not covered | success/flag/getattr/setattr errors |
| removeItem | not covered | success/name/remove errors |
| renameItem | not covered | success/name/rename/replacement paths |
| enumerateDirectory | not covered | success, stale verifier, dot/dotdot pack-stop, readdir error, entry pack-stop |
| read | not covered | success, invalid offset, bridge/buffer error |
| write | not covered | success, invalid offset, flags/getattr/write errors |
| blockmapFile | not covered | success/partial/packer-stop, invalid offset, RO, map/purge error, retained-ID ownership |
| completeIO | not covered | tracked/cached success, invalid offset, map/purge/bridge errors, failed I/O, RO |
| createFile/lookupItem(packer:) | not covered | forwarding success/error |
| createSymbolicLink/createLink/readSymbolicLink | not covered | ENOTSUP reply |

This is an acceptance gap, not an assertion that uncovered paths are safe. In particular the existing condition waits are not proven hang-proof by this wave. No complete G1 table is claimed.

### G2 — host restrictions

Respected. Only headless image-file/package tests, harmless Python subprocess tests, and the requested generated Debug build were executed. No host filesystem was mounted/attached, no driver installed, no daemon killed, no forced cleanup, no signing/notarization operation outside the existing requested Debug ad-hoc build phase.

## Full verification

- Plain `swift test`: exit 0, artifact 522. Probe/policy 17; glue 12; bridge 25. Bridge suite 395.121 s, `readMatchesNtfscat` 395.120 s. This run included all substantive production changes. A later edit only removed the unused poisonFreeClusters test helper.
- AddressSanitizer `swift test --sanitize=address`: exit 0, artifact 524. All 17 probe/policy + 12 glue + 25 bridge tests passed. Bridge suite 384.009 s; no ASan error reported.
- UBSan: exit 0, artifact 526; all 17 probe/policy + 12 glue + 25 bridge tests passed (bridge 411.334 s), no runtime error reported. Exact command: `env UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 swift test --sanitize=undefined -Xlinker /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/21/lib/darwin/libclang_rt.ubsan_osx_dynamic.dylib -Xlinker -rpath -Xlinker /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/21/lib/darwin`. This is the documented explicit runtime-link method, not an unlinked baseline run.
- Repository root `python3 scripts/test-bench.py && python3 scripts/test-seqio.py`: 3 + 2 tests OK.
- `xcodegen generate && xcodebuild -scheme YuzuNTFS -configuration Debug build`: exit 0, artifact 521, `** BUILD SUCCEEDED **`. Existing SDK completion-nullability and upstream conversion/packed-member warnings remain visible.

## Commits

- 0b675fb — fix(engine): close metadata, sparse allocation and lifecycle safety gaps
- 7e8cf00 — fix(module): reconcile read-only state and balance item and engine lifetimes
- 335996d — fix(scripts): supervise benchmarks and reject unsafe write targets

## Remaining acceptance / limitations

G1 remains incomplete, and F3 plus the actual-mount half of F6 lack requested RED-before-fix evidence. E7's fault RED did not replay the old size-publication failure because F-R2 had already removed it. E8 is unreachable/moot per F-R1, not tested as an authorized sparse-write path. Safe sparse writes, T7-R5 reverse/unreported ordering, symlink-target/ADS mutations and owner mounted/macOS26/hardware/chkdsk gates remain outside implemented P0 behavior. No claim of resolved kernel wedge or production safety is made.

Additional static G1 risk identified but not exercised/fixed: blockmapFile and completeIO validate offset but directly convert Int length to UInt64; negative lengths can trap before a reply. read likewise lacks a negative-length check before passing its count into the C bridge. This is not covered by the existing green suite and must be addressed before claiming the reply-once invariant.
