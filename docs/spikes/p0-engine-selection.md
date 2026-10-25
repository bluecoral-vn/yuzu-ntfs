<!-- SPDX-License-Identifier: GPL-2.0-only -->
# P0 gate — engine E2 selected

## Decision

**Select E2, provisionally: TT NTFS Native `core/` + `platform/` at `36cc849a3ed867b8b6ee3fbc805ba2385cb79cdb`.** E1 is deferred, not an implemented engine that lost a measured race. Controller ruling T6-R2 replaces the planned E1 build with the [feasibility investigation](p0-e1-feasibility.md): pristine Linux v7.3 requires an estimated 4–8k LOC compatibility layer [INFERENCE] beyond this spike. E1 has no correctness result, so E2 wins the first available criterion by default. No EngineE1 target or Linux E1 vendor copy remains to delete.

Under P9, selection uses criteria 1, 3, 4 and 5 now. **Criterion 2 remains PENDING-OWNER and can overturn this decision.** This is a P0 engineering decision, not production-safety or final hardware-performance acceptance. Ruling P-R1 closes R3 for P0 as **“VM-indicative within target band; formal medians on physical SSD PENDING-OWNER.”** It does not turn incomplete benchmark samples into passing formal ratios.

Controller authority: [progress ledger, Rulings P7–P9, T6-R2 and P-R1](../../.superpowers/sdd/2026-10-24-yuzu-ntfs-p0-platform-spike/progress.md).

## Ordered selection criteria

| Criterion | E1 | E2 evidence and result |
|---|---|---|
| 1. Conformance + fixture correctness | Deferred under T6-R2; no built engine, conformance count or mounted correctness result. | Latest shipping code `eb69b12`: **17 probe + 50 actual-module glue + 35 bridge = 102 tests per matrix**, passing plain, ASan and linked UBSan (306 executions); external monitor Python matrix **49 tests**. Earlier fixture conformance included **100,028 ntfscat entry comparisons**; that corpus count is not a test count. macOS 27 VM full functional acceptance PASS: RO basic/names/bigdir hashes and 100000-entry enumeration, resident append/remount, exact 1000003-byte copy/EOF/remount, VDL zero tails/remount, ADS refusal, pre-latch FD EROFS and M-R1 retained-mapping assertions. Real blockmap/completeIO callbacks observed. [Final verification and VM acceptance](p0-r3-throughput.md#final-code-verification-and-controlled-qos). **E2 selected at this criterion.** |
| 2. Windows `chkdsk /scan` after write torture | Not run. | **PENDING-OWNER**: Windows oracle unavailable; no error count claimed. Must run create/rename/delete 10000 files, five fragmented 200 MiB files and ADS, then retain chkdsk output/error count. P9 permits re-selection on this evidence. |
| 3. Sequential + small-file throughput | No bench rows. | See actual performance-pass rows below and [R3 evidence](p0-r3-throughput.md#performance-pass-2-2026-10-25). VM-indicative only under P-R1; formal medians, native/raw/exFAT denominators and small-file ratios not established. |
| 4. Maintained diff vs upstream | Absent/deferred; no comparable size. | `scripts/upstream-diff-stat.sh` run for this decision: **1131 physical C/header glue lines in 5 files; upstream patches +0/-0; maintained total 1131**. Exact output below. This is integration surface, not a similarity comparison to Linux. |
| 5. Licence / attribution | No E1 source ships; investigation preserved GPL-2.0-or-later and optional MIT decompressor notices. | Whole repository GPL-2.0-only; pristine TT subset retains its per-file SPDX expressions, including GPL-2.0-or-later, and `upstream/ttntfs/LICENSE` plus `COPYRIGHT`. [Pinned provenance](../../upstream/README.md) records source, commit and subset; bridge/build integration stays outside upstream. No proprietary/open split. |

### Recorded upstream-diff-stat output

```text
EngineE2: baseline=upstream/ttntfs; glue=1131 physical C/header lines in 5 files; patches=+0/-0; maintained_total=1131
EngineE1: absent — deferred under T6-R2; no E1 size comparison is available.
Excludes pristine vendored files, symlinked sources, docs, build configuration and tests.
Totals measure maintained integration surface, not a similarity diff between unrelated glue and kernel files.
```

### Recorded performance passes (not formal medians)

| Pass / environment | Workload | Observed result |
|---|---|---|
| Pass 1, headless before/after | Sequential write / small files / metadata purge | 2.5× / 2.9× / 660× improvements; not hardware acceptance ([pass 1](p0-r3-throughput.md#performance-pass-2026-10-25)) |
| Pass 1, VM | Initial mount | 31.957127 s; functional PASS, historical performance NO-GO |
| Pass 2, background-QoS VM | Mount; first sequential pair | 2.691257 s; write 465.077 / read 631.459 MiB/s, single samples |
| Pass 2, normal-QoS VM, run 1 | 4 GiB write / read | 4.170534 s / 982.128 MiB/s; 1.386387 s / 2954.443 MiB/s |
| Same, run 2 | 4 GiB write / read | 8.022591 s / 510.558 MiB/s; 1.474344 s / 2778.185 MiB/s |
| Same, run 3 | 4 GiB write / read | 7.306372 s / 560.607 MiB/s; 2.605082 s / 1572.311 MiB/s |
| Same, run 4 | 4 GiB write / read | 8.990692 s / 455.582 MiB/s; read NOT REACHED |
| Same, run 5 | Sequential pair | NOT REACHED |
| Same | Initial mount / remounts | 0.051235 s / 0.197829–0.581500 s |
| Same | Copy 10000 × 4 KiB; ls / rm 100000; raw / Apple NTFS / exFAT reference | NOT REACHED / NOT RUN; no current ratios or CPU claim |

After write 4 an owned diskimages-helper stayed U for 20.8 s: the unchanged V-R4 stop revoked authorization. Physical hardware is needed to resolve this VM/backing-image limitation; causality is not established. Different-QoS and historical raw/exFAT rows are not substituted as denominators.

## P0 gate summary

| Gate | Status | Evidence / remaining boundary |
|---|---|---|
| R1 — normal-user FSKit enablement | **PROVISIONAL** | [R1 enablement](p0-r1-enable.md): signed/notarized module invoked on macOS 27 without sudo/security changes; only undocumented per-user fallback demonstrated. GUI toggle and macOS 26 **PENDING-OWNER**. |
| R2 — Yuzu selected instead of Apple NTFS | **PROVISIONAL** | [R2 selection](p0-r2-automount.md): automatic image selection proved on macOS 27; its early ENOTSUP describes the pre-engine build, not today's engine. [Later VM mounted acceptance PASS](p0-r3-throughput.md#final-normal-qos-functional-gate-and-timed-rows) proves functional RW on disposable images, not physical automount/remount acceptance. Physical/partitioned/Windows-made media and macOS 26 **PENDING-OWNER**. |
| R3 — KOIO functional + throughput | **PROVISIONAL** | [R3 performance pass 2](p0-r3-throughput.md#performance-pass-2-2026-10-25): VM functional **PASS** under M-R1. P-R1: **VM-indicative within target band; formal medians on physical SSD PENDING-OWNER**. No formal ≥90% raw/exFAT or Apple-NTFS comparison claimed. |

**P0 closes provisionally under controller rulings, not as an unconditional product gate PASS.** No valuable media is authorized: RW remains restricted to explicitly allowlisted disposable fixtures (T7-R1).

## Full PENDING-OWNER list

- **GUI toggle / no-Terminal enablement:** perform the actual normal-user Settings enablement and validate the product path; public Settings opener alone does not enable the module (R1).
- **macOS 26:** enablement, precedence, RO/RW functional acceptance, reported mount flags (especially 26.0–26.3), and throughput on the supported OS floor (R1/R2/R3).
- **Physical SSD medians + surprise removal:** five-run sequential and small-file/reference medians on the reference SSD, real raw-device baseline, CPU observations, physical plug-in/unplug and surprise-removal safety; include Windows-formatted GPT/MBR media and real automatic RW/remount behavior (P7/P8, R2/R3). Image/VM evidence is not a substitute.
- **Windows chkdsk:** provide Windows licence/ISO/VM and run the complete criterion-2 torture subset followed by `chkdsk /scan`, recording errors; selection can be overturned (P4/P9).

## Open P1 items and bounded P0 limitations

These remain open, not implicitly resolved by engine selection; see the [controller ledger](../../.superpowers/sdd/2026-10-24-yuzu-ntfs-p0-platform-spike/progress.md).

- **T7-R4 — promote on write-open:** existing RW resident files currently promote on the first read or write blockmap. Move promotion to OpenClose write-open and establish whether dynamic inhibit changes are honored; listing/lookup must remain nonmutating.
- **T7-R5 — unreported cached-write ordering:** a cached write beyond VDL reported after a higher write's completion can be erased by gap zeroing. Design pending-write range tracking/ABI or prohibit cacheable mappings beyond VDL; fixture-only RW bounds the P0 risk.
- **F-R1 — sparse writes:** sparse files remain readable but write-open, size changes and write mappings return EPERM. Implement safe allocate → zero → publish with TT allocation/mapping-pair updates before enabling sparse writes; do not weaken this guard.
- **M-R1 — mapping revocation:** retained, already-allocated kernel mappings may change data after the RO latch, without new allocation, size/VDL/metadata changes and with prompt completion. Investigate macOS 27 `DataCacheHandler.setCacheState(push/invalidate)` revocation.
- **E1 revisit:** revisit the pristine Linux port after v0.1 if TT stalls (T6-R2); no fake E1 target or shim is retained.
- **Compressed-write narrowing defects:** two dormant pristine-TT compression narrowing warnings remain documented by pre-deploy QC. Compressed writes are inhibited/rejected, not repaired; fix and test before expanding that scope.
- **Undocumented enablement path:** replace/validate the fallback with the documented Settings product flow; no shipping approval for direct settings-plist/user-agent manipulation (R1, T3-R1).
- **Q-R2:** remove the P0-only force-RO fault hook when implementing the P1 production path; this test mechanism is not a user feature.
