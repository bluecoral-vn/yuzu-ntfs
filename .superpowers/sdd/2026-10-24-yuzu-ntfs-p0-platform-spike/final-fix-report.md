# Final fix report — base 1b91297

## Verdict

**Latest targeted round complete: N1–N4 and T1–T3 are addressed, with the final-source matrix passing.** G1 is evaluated under Main's amended FR-1 complete static reply-path audit; the earlier incomplete/exhaustive-runtime verdicts below are retained as historical wave evidence and superseded by the targeted FR-1 section. Actual SDK branch tests are not claimed where unexercised. No upstream file was edited, no ABI member reordered, and no push, host mount/attachment, installation, disk-management probe or notarization performed. FR-2 permits the existing ad-hoc Debug build phase only. T7-R1, T7-R4 and T7-R5 remain binding. Owner transport recovery/reboot and mounted acceptance remain outstanding; these fixes do not prove the kernel wedge resolved.

Commands below ran from `Packages/NTFSCore` unless a repository-root command is shown. `swift test --filter NAME` denotes the exact focused invocation, not a hypothetical check. Earlier wave counts are preserved with their evidence; the latest FR-1 matrix passed 17 probe/policy + 24 glue + 27 bridge tests, including every original fixture-entry comparison.

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

The static negative-length risk described during the first handoff is fixed by the G1 continuation below. G1 is still incomplete for the separately listed uncovered handlers/branches.

## G1 continuation after Main's instruction

Production changes: `YuzuNTFSVolume.swift` validates nonnegative offset/length and signed endpoint bounds before casts or item locks; read/write/blockmap/completion invalid ranges reply EINVAL once. Timestamp inputs use overflow-reporting arithmetic and reject invalid nanoseconds. Caller-supplied FSItem conversion now throws EINVAL instead of force-casting; open/close validate even read-only/no-op modes. `YuzuNTFSItem.normal` and contending explicit blockmaps return EBUSY instead of waiting for another callback's completion. The retained operation is not released by the rejected request.

RED: `swift test --filter invalidIORangesReplyExactlyOnceWithoutTrapping` (532) terminated with `Fatal error: Negative value is not representable`. GREEN same command (534): one test passed. RED: `swift test --filter retainedMappingDoesNotBlockUnrelatedHandlerForever` (536): deadline timed out and result was 0 instead of EBUSY. The regression explicitly releases the old wait after recording RED so it leaves no wedged test worker. GREEN observed in 538. Unknown-item regression initially found open/close still returned success (538); those handlers now validate their items.

`realVolumeHandlersReplyOnceForBridgeSuccessAndErrors` drives actual handlers under bridge status 0/EIO/EROFS/ENOENT, asserts exactly one closure invocation, and asserts elapsed <0.5 seconds. It exercises synchronize, getattr, setattr, ordinary and KOIO-wrapper lookup/create, remove, rename, buffered write, write-open, close, zero-length blockmap/completion, ENOTSUP symlink/hardlink/readlink, reclaim, mount and unmount. `unknownItemsReceiveOneErrorReply` exercises invalid FSItem open/close/get/set/lookup/create/remove/rename/reclaim/write. Numeric-invalid read/blockmap/completion and write-overflow are separately exercised. These tests passed in the plain phase of the final sequential matrix (16 glue tests total).

Updated coverage table (supersedes corresponding first-wave rows above):

| Handler | Real-handler paths now covered | Still not driven |
|---|---|---|
| synchronize/getAttributes/setAttributes | success and bridge EIO/EROFS/ENOENT; unknown item for get/set | timestamp invalid boundaries; size policy variations |
| lookup/create plus KOIO forwarding overloads | success and bridge EIO/EROFS/ENOENT; unknown directory; initial-attribute failure rollback | name conversion, pin failure in lookup/create, rollback failure |
| remove/rename/write/open | success and bridge EIO/EROFS/ENOENT; unknown items; invalid write endpoint; effective RO open | every replacement/flag/forced-RO variation |
| close/reclaim/mount/unmount | ordinary success; unknown close/reclaim; activate/deactivate lifecycle regressions retained | SDK tryReclaim refusal/success distinction; stale already-reclaimed identities |
| blockmapFile | zero-length success; negative/overflowing range; busy-mapping rejection implemented | actual SDK packer data/zero-fill/stop and purge failures; unknown-item invocation not included |
| completeIO | zero-length success and bridge errors; negative/overflowing range | nonempty tracked/cached/purge failures and already-reclaimed item |
| read | negative/overflowing range reply-once | actual SDK mutable buffer success/error; no public buffer initializer was used |
| createSymbolicLink/createLink/readSymbolicLink | ENOTSUP reply exactly once | no supported success path in P0 |
| enumerateDirectory | no new handler test | stale verifier, packer stop, actual entries and bridge errors |
| filesystem probe/load/unload | no new handler test | all three; FSKitGlue target does not yet include filesystem source |

No structural static reply-path guard was added. A generic callback counter cannot prove all paths or prevent a future missing reply. The continuation closes concrete traps/waits and broadens actual-handler tests, but **does not satisfy exhaustive G1 acceptance**. The caller-supplied device-size conversion paths in `YuzuNTFSFileSystem` and every SDK resource-backed packer/buffer path still require review/test harness extension. No claim is made that the coverage gaps are impossible to drive; they remain unfinished.

### Namespace/shrink correction requested by Main

`removeItem` and `renameItem` no longer enter item mapping guards: namespace unlink/replacement is serialized at the bridge and relies on existing inode pins/deferred freeing, so even an explicit in-flight mapping does not cause EBUSY for name removal. `changingSize` rejects only an explicit operation whose recorded extent crosses the requested new EOF; it does not reject retained cached mappings or completed operation IDs. Metadata-only setattr and non-overlapping size changes proceed immediately.

SDK evidence: Xcode macOS 27 SDK `FSVolume.h:665–688` specifies growth zero semantics (`669–671`) and shrink/freeing (`673`), but provides no drain/invalidation guarantee in this setter contract. `FSVolumeExtent.h:139–142` explicitly says the kernel retains unspecified/F_LOG2PHYS mappings and can perform I/O at any time. Therefore no blanket drain assumption is made: only a currently recorded explicit operation overlapping the removed tail returns EBUSY. A completed explicit operation clears the lease; retained cached mappings do not own one. `FSVolume.h:397–407` describes open-unlink emulation; E2's own pins supply the namespace/deferred-free mechanism.

`namespaceRemovalDoesNotWaitForExplicitMapping` checks remove and rename succeed immediately despite an explicit outstanding range, overlapping size-to-zero returns EBUSY, and the same size request succeeds after completion clears the explicit operation. It passed in the plain phase of the final 17-glue-test matrix. The existing real-image `removedAndReplacedItemsRetainAllocationUntilReclaim` continues checking inode/cluster pin lifetime; the new namespace test uses the real volume handlers over the injected bridge, not an additional real-image raw-map removal fixture. This distinction is retained as a coverage limitation.

The earlier 16-test verification command was cancelled after this correction changed production code. A replacement complete sequential plain/ASan/linked-UBSan/Debug-build matrix was started against the corrected final sources.

### Latest continuation verification — final production sources

The complete sequential command is the four commands already specified above joined by `&&`: plain suite, ASan suite, explicitly linked UBSan suite, then `xcodegen generate && xcodebuild -scheme YuzuNTFS -configuration Debug build`. It exited 0 (artifact 543); each suite reported 17 probe/policy + 17 glue + 25 bridge tests. Bridge durations: initial plain 379.273 s, ASan 462.255 s, UBSan 446.466 s. Debug emitted `** BUILD SUCCEEDED **`; no ASan/UBSan runtime error was reported. The last ordinary-growth-versus-shrink discrimination correction landed before the ASan and UBSan builds; therefore a final plain run was also executed afterwards to cover that exact final source: `swift test --package-path Packages/NTFSCore`, exit 0, artifact 545, 17 + 17 + 25 tests, bridge 424.368 s. No production source changed after these final sanitizer/build phases.

Final status remains **G1 INCOMPLETE** for the explicit uncovered paths in the table, not a complete no-hang guarantee. Namespace removal no longer depends on completion callbacks, and size growth is not rejected merely because a pending write extends farther; EBUSY applies only to an explicit overlapping tail during actual shrink.

## Targeted re-review FR-1 / FR-2 — N1–N4 and T1–T3

This section supersedes the earlier G1 acceptance statements: Main amended G1 to a **static complete-entrypoint reply audit**, rather than reinstating the previously requested exhaustive runtime matrix. `agent://FinalReReview` audited all Module entrypoints and found one reply on every ordinary/thrown-error return, subject to T1–T3's remaining trap sites. This round closes those sites. Runtime test gaps remain disclosed; they are not reclassified as exercised tests. FR-2 explicitly permits the existing ad-hoc Debug build phase; G2 prohibits mounted/attached/installed/notarized testing, all of which remain unattempted.

### N1 — atomic EOF / shrink classification

Files: `Module/YuzuNTFSItem.swift`, `Module/YuzuNTFSVolume.swift`, `HandlerTests.swift`.

The setter now enters `changingSize`'s item I/O lock, then the volume serialization lock, before reading EOF. It classifies actual shrink, checks overlap against the current explicit-operation extents, applies the size and builds final attributes without releasing either lock. The stale pre-lock EOF snapshot and classification are removed. Namespace remove/rename remain outside mapping-lease exclusion.

Regression: `concurrentGrowthCannotTurnOldGrowthSnapshotIntoUnsafeShrink`. A DEBUG-only scheduling hook interleaves request A (8 KiB → 12 KiB) with B's actual setter growing the injected bridge state to 16 KiB and an explicit [12 KiB,16 KiB) mapping model. A must return EBUSY, preserve 16 KiB and preserve the mapping's physical extent. This is a deterministic handler/bridge-double interleaving, not a kernel-issued mapping or physical-media test.

- RED: `swift test --filter concurrentGrowthCannotTurnOldGrowthSnapshotIntoUnsafeShrink`, artifact 557: reply error nil rather than EBUSY; final size 12288 rather than 16384; two issues.
- GREEN: `swift test --filter 'concurrentGrowthCannotTurnOldGrowthSnapshotIntoUnsafeShrink|namespaceRemovalDoesNotWaitForExplicitMapping'`, artifact 559: two tests passed.

### N2 — startup signals and authorization ownership

Files: `scripts/bench_supervisor.py`, `scripts/bench.sh`, `scripts/test-bench.py`.

SIGINT/SIGTERM are blocked before installing handlers/forking. The whole parent post-fork lifetime is within cleanup scope. The child establishes its process group and waits on a go-pipe before doing any work; EOF exits without proceeding. The parent unmasks pending startup signals inside its protected try, grants authorization itself, then releases the child. `bench.sh` no longer grants authorization after returning into the worker. Thus a surviving child cannot reauthorize after parent revocation. Every catchable parent exit revokes before attempting SIGTERM, without a blocking reap or force cleanup. Cleanup is also protected against pipe-close errors and the close/descriptor-state signal window.

Regression: `BenchPreflight.test_termination_during_parent_setup_never_releases_worker` injects SIGTERM during the parent's `setpgid` setup, before the old supervising try. A child which incorrectly escapes release writes a reauthorization marker.

- RED: repository-root `python3 scripts/test-bench.py BenchPreflight.test_termination_during_parent_setup_never_releases_worker`: return code 1 rather than 143.
- GREEN: repository-root `python3 scripts/test-bench.py`: four tests OK, including the startup signal, normal deadline, image/driver preflight mismatch and mounted-identity subprocess doubles. No disk commands run.
- A later combined verification attempt exposed `PermissionError: [Errno 1] Operation not permitted` delivering SIGTERM to the owned group after startup cancellation. The supervisor now explicitly reports failed delivery and surviving PID/group, preserves its failure exit status, and does not attempt escalation, an unbounded reap or forced cleanup. Authorization is already revoked and unreleased startup workers cannot pass their go-pipe. This diagnostic is not described as successful signal delivery.

### N3 — buffered gap growth stays non-sparse

Files: `engine.c`, BridgeConformanceTests.

Before a nonempty buffered write extends beyond physical allocation, E2 promotes as necessary and calls the existing non-sparse preallocation primitive through `e2_prepare`, keeping EOF/VDL unchanged. TT's subsequent buffered writer still owns EOF/VDL and gap-zero bookkeeping, but cannot create sparse gap runs in the now-allocated range. Initially sparse files still return EPERM under F-R1.

Regression `bufferedGapGrowthStaysWritableAndNonSparse`: write at 1 MiB, assert no sparse flag, assert a second write succeeds, then compare the entire zero gap plus payload.

- RED: `swift test --filter 'bufferedGapGrowthStaysWritableAndNonSparse|sizeOnlyGrowthUpdatesModificationAndChangeTimes'`, artifact 551: sparse flag 8; second write EPERM; incorrect resulting bytes.
- GREEN: same command, artifact 553: both tests passed (0.017 s combined).

### N4 — growth timestamp / dirty bookkeeping

Files: `internal.c`, BridgeConformanceTests.

Successful low-level growth updates mtime/ctime, marks filename metadata dirty and marks the inode dirty, retaining F-R2's physical-allocation and unchanged-VDL semantics. Explicit timestamp attributes are still applied after size.

Regression `sizeOnlyGrowthUpdatesModificationAndChangeTimes`: grow a real image's nonresident file, then require both times to advance.

- RED: combined command above, artifact 551: mtime and ctime both remained exactly 134372544883158690.
- GREEN: same command, artifact 553: both tests passed.

### T1 — NSError narrowing

Files: `YuzuNTFSItem.swift` (shared boundary helpers), `YuzuNTFSDevice.swift`, `YuzuNTFSVolume.swift`.

All device error translations and completion-status translation use `Int32(exactly:)`, mapping an unrepresentable NSError code to EIO. This is nonthrowing and cannot terminate a reply path.

Regression `completionMapsUnrepresentableErrorCodeToEIO` drives the real completion handler with NSError code Int.max and verifies the bridge receives EIO and the reply runs once.

- RED: `swift test --filter completionMapsUnrepresentableErrorCodeToEIO`, artifact 561: `Fatal error: Not enough bits to represent the passed value`.
- GREEN: four-test boundary command in artifact 566: passed.

### T2 — geometry validation before allocation/narrowing

Files: `YuzuNTFSItem.swift`, `YuzuNTFSDevice.swift`, `YuzuNTFSFileSystem.swift`, the new filesystem-source symlink in FSKitGlue, `HandlerTests.swift`.

`YuzuNTFSGeometry` checks exact Int/UInt32 conversions, supported logical sectors (512/4096), nonzero count, bounded power-of-two physical sector, multiplication overflow and the signed device-offset range. Scratch allocation and bridge descriptors use validated stored geometry. Probe/load validate before allocation and catch EINVAL/EOVERFLOW; read lengths are checked before constructing raw buffers. Device construction and the resource-based volume initializer now throw; the load handler catches them.

- RED `swift test --filter unrepresentableDeviceGeometryIsAnErrorNotATrap`, artifact 564: the actual device constructor trapped converting UInt64.max blockSize to Int.
- GREEN boundary command, artifact 566: passed.
- `geometryOverflowRepliesFromFilesystemHandlers` drives actual probe/load handlers on an in-memory FSBlockDeviceResource subclass with oversized geometry, asserting exactly one EOVERFLOW reply without any resource I/O. `invalidGeometryProductsAndPhysicalRangesAreChecked` covers overflowing count products, invalid/zero geometry, unrepresentable physical sizes and arithmetic helpers. Both passed in artifact 570.
- FSKitGlue now compiles the actual `YuzuNTFSFileSystem.swift` through the same source-symlink convention as the volume/device/item sources.

### T3 — checked producer-boundary arithmetic

Files: `YuzuNTFSItem.swift`, `YuzuNTFSVolume.swift`, `YuzuNTFSDevice.swift`, `HandlerTests.swift`.

Reference translation and enumeration cookies use checked UInt64 addition. Attribute construction can throw through its callers. Directory callback errors are stored on the synchronous enumeration context, stop enumeration and reach the single outer error reply. Full logical/physical mapping ranges and each signed offset conversion are checked before packing. Purge computes checked physical endpoints rather than overflowing Int64/UInt64 additions.

- RED `swift test --filter overflowingReferenceRepliesWithErrorRatherThanTrapping`: process exited with unexpected signal 5 before replying.
- GREEN boundary command, artifact 566: reference overflow replied EOVERFLOW once.
- `overflowingBridgeCookieAndPhysicalRangeReplyOnce` injects UInt64.max enumeration cookies and physical mappings into real handlers. Both reply EOVERFLOW once before using the SDK packer. It passed with the namespace/broad-handler regressions in the focused command preceding the full matrix.

### Updated static reply-once audit rows

The complete unchanged entrypoint inventory and normal/thrown return-path trace is in `agent://FinalReReview`'s Reply-once audit. The following rows supersede its T1–T3 qualifications and N1 race finding:

| Entrypoint / shared path | Final returning-path result | Runtime evidence / qualification |
|---|---|---|
| probeResource | Non-block guard, geometry error, read/format error and usable result each reply once; allocation is bounded by validated geometry | Actual invalid-geometry handler regression; valid-resource I/O remains a device-progress dependency |
| loadResource | Invalid resource/geometry/read/parse/throwing device construction all converge on one error reply; valid construction replies one volume | Actual oversized-geometry load regression; no mounted load |
| getAttributes and attribute-producing setters | Reference-ID overflow throws EOVERFLOW to the existing single catch/reply | Actual UInt64.max ref regression |
| setAttributes | EOF query, shrink classification, overlap guard and mutation occur under item+volume locks; every thrown branch unwinds both locks before the one error reply | Deterministic A/B size interleaving; existing namespace/shrink regressions |
| enumerateDirectory | Dot-entry ID errors throw to outer catch; entry callback ID/cookie/attribute errors stop via context.error, then outer catch replies once | Actual overflow-cookie callback regression; normal SDK packer-full branches retain the prior static trace |
| blockmapFile | Caller range/item guards reply-and-return; map/purge/range/offset errors release the matching explicit lease and unlock before replying once; packer-stop reaches one success reply | Actual physical overflow regression; no unchecked physical offset narrowing remains |
| completeIO | Unrepresentable NSError status maps to EIO before C; tracked/cached map/purge/bridge errors still converge on one catch; matching lease is cleared by defer | Actual Int.max status regression; original completion-order tests retained |
| device read/write/flush callbacks | Geometry is validated at construction; range validation precedes narrowing; NSError translation cannot trap | Constructor and shared-boundary regressions; callbacks can still wait for actual device progress |
| all remaining implemented FSKit handlers / synchronous properties | Original FinalReReview return-path audit unchanged: one reply on every returning handler path, or a synchronous property with no reply closure | Earlier handler tests retained; no claim that every SDK-mediated branch was dynamically exercised |

There is no introduced async dispatch or wait for a future completeIO callback. Ordinary mutex waits, synchronous device access, page-cache writeback and no-I/O disposal's drain of an already-running callback remain dependent on device/core progress. The static reply-once result is **not** an unconditional latency guarantee for wedged kernel/device I/O, and does not establish resolution of the original host wedge.

### Final FR-1 verification and disposition

Final-source command, repository root, executed sequentially:

```sh
python3 scripts/test-bench.py &&
python3 scripts/test-seqio.py &&
swift test --package-path Packages/NTFSCore &&
swift test --package-path Packages/NTFSCore --sanitize=address &&
env UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
  swift test --package-path Packages/NTFSCore --sanitize=undefined \
  -Xlinker /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/21/lib/darwin/libclang_rt.ubsan_osx_dynamic.dylib \
  -Xlinker -rpath \
  -Xlinker /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/21/lib/darwin &&
xcodegen generate &&
xcodebuild -scheme YuzuNTFS -configuration Debug build
```

Exit 0, artifact 579. Python: **4 benchmark + 2 seqio tests OK**. Each Swift matrix entry passed **17 probe/policy + 24 FSKit glue + 27 bridge tests (68 total)**. Bridge durations: plain **439.010 s**, ASan **413.657 s**, linked UBSan **396.656 s**. No ASan/UBSan runtime error reported. All original fixture/ntfscat comparisons remain included. Xcode output: `** BUILD SUCCEEDED **`; the existing SDK completion-nullability warning remains disclosed. No production source changed after this verification started.

Logical implementation commits for this targeted round:

- `82b5a32` — fix(engine): preserve buffered growth allocation and resize timestamps
- `c53c835` — fix(module): serialize shrink decisions and check FSKit numeric boundaries
- `dc0bafd` — fix(scripts): fence worker startup and parent-only authorization

**Items not fixed from the targeted list: none.** E8 remains waived/unreachable under F-R1. G1's static returning-path audit is addressed; exhaustive SDK-mediated runtime coverage was superseded by Main's FR-1 ruling, not fabricated as passing. Synchronous device/core progress, owner reboot/mounted/hardware acceptance and the previously documented P1 functionality/ordering limitations remain unchanged.
