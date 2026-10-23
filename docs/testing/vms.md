# VM interoperability testing

## Status and safety

**PENDING-OWNER:** neither a Windows VM nor a macOS 26 VM was available for this task. No VM boot, Windows drive visibility, or `chkdsk` result is claimed. The offline generator and ntfsprogs readback do not substitute for those gates.

Use a dedicated **copy** of the generated images. Never pass a real user disk, the only copy of data, or a writable fixture ground-truth image into a VM. Shut down the guest fully before changing storage configuration. Never attach an image writable in two guests, or in a guest and the host, simultaneously.

Run `scripts/make-fixtures.sh` on the host first. `basic-512.img` is a raw 256 MiB NTFS volume with no partition table (a superfloppy), not a bootable disk. The VM boots its own separate system disk. Keep its sibling manifest on the host. Repeat tests with the other fixtures once the basic volume gate passes; the 4kn image additionally needs a virtual device exposing a 4096-byte logical sector and must not silently be treated as a 512-byte device.

## Windows 11 ARM in UTM

1. **PENDING-OWNER — boot:** create or use an Apple Silicon UTM **virtualized Windows 11 ARM** VM with its own Windows system disk, UEFI and the UTM guest tools/drivers. Install Windows from a licensed owner-provided ARM image. Boot and record Windows version, UTM version and successful desktop login.
2. Shut Windows down. Make a disposable host-side copy, for example `cp fixtures/basic-512.img /tmp/yuzu-basic-windows.img`.
3. In UTM's VM settings, add/import the existing `/tmp/yuzu-basic-windows.img` as a drive. Keep the format **raw** (`.img`), and select **USB/removable** interface for this partitionless volume. Do not convert, initialize, repartition or format it. Leave the original Windows boot drive first in the boot order. For fixed/virtio disks, install the ARM storage driver first; Windows may not expose a partitionless fixed disk as a drive, which is a device-presentation problem rather than proof of filesystem corruption.
4. **PENDING-OWNER — drive visibility:** boot Windows. Check Disk Management for the extra 256 MiB NTFS volume labelled `Yuzu-basic-512`. If offline, bring only this test disk online; assign an unused letter such as `X:` to the recognized NTFS volume. Cancel any prompt to initialize or format. If UTM's selected controller cannot present the raw volume as removable, stop and record the controller/version; do not modify the source fixture to make the test look successful. A separately constructed partitioned wrapper can be evaluated later without replacing the raw fixture.
5. Confirm `X:\resident.txt`, `X:\nonresident.bin`, `X:\fragmented.bin`, `X:\ads.txt` and `X:\subdir\nested.txt` exist. In PowerShell, `Get-Item X:\ads.txt -Stream *` should show `metadata`; in an elevated Command Prompt, `fsutil hardlink list X:\resident.txt` should include `resident-hardlink.txt`. Compare file sizes and `Get-FileHash -Algorithm SHA256` with the host manifest. The `.txt` contents are intentional binary patterns.
6. **PENDING-OWNER — filesystem scan:** in an elevated terminal run `chkdsk X: /scan`. Save the complete output and exit status, including any inability to run an online scan. Do not silently replace `/scan` with a repair mode. Any subsequent repair test uses a fresh disposable copy and must record that it wrote to disk.
7. Shut Windows down before detaching the image. Preserve logs, not a modified replacement for the fixture. Re-run the host's fixture script if the source was accidentally modified; its checksum cache rejects mutated images.

## macOS 26 with Virtualization.framework

1. **PENDING-OWNER — boot:** use Apple's Virtualization.framework macOS VM sample/host app on Apple Silicon. Download a compatible **macOS 26** IPSW restore image (do not accept a “latest” image that resolves to macOS 27), create the auxiliary storage, hardware model and machine identifier from its supported configuration, install to a separate macOS system disk, and boot to desktop. Record the host OS, guest OS/build and restore image version. A VM configuration is not evidence that installation or boot succeeded.
2. Shut the VM down and copy `fixtures/basic-512.img` to a disposable path such as `/tmp/yuzu-basic-macos.img`.
3. Attach the copy as an additional **virtual disk**, not as the system/boot disk. In the host app's configuration construction (before `validate()` and VM start), use this standard Virtualization.framework configuration, preserving all existing system-disk entries:

   ```swift
   let attachment = try VZDiskImageStorageDeviceAttachment(
       url: URL(fileURLWithPath: "/tmp/yuzu-basic-macos.img"),
       readOnly: true
   )
   let fixtureDisk = VZVirtioBlockDeviceConfiguration(attachment: attachment)
   configuration.storageDevices.append(fixtureDisk)
   try configuration.validate()
   ```

   A raw unpartitioned NTFS volume is appropriate for guest `diskutil` inspection. Do not run `hdiutil convert` or add a partition map to the source. Use read-only attachment for initial inspection; change to writable only for later explicitly provisioned driver tests on a new copy.
4. **PENDING-OWNER — device visibility:** boot macOS 26 and run `sw_vers`, `diskutil list` and `diskutil info /dev/diskN` for the new 256 MiB device. Identify it by size and volume label, never by assuming a stable disk number. Save command output. macOS's built-in NTFS behavior is not evidence that the Yuzu extension loaded.
5. The current Task 1 extension deliberately reports “not recognized” and `ENOTSUP`. Ad-hoc packaging alone cannot authorize FSKit loading. Do not attempt Yuzu write/mount verification or weaken SIP/AMFI here; development provisioning, extension activation and real mount tests belong to the later platform tasks.
6. Shut the guest down before detaching the virtual disk. Record any attachment or guest discovery failure verbatim.

## Owner evidence to close the pending gates

| Gate | Current status | Required evidence |
|---|---|---|
| Windows 11 ARM boots in UTM | PENDING-OWNER | UTM/Windows versions, desktop boot confirmation |
| Windows sees `basic-512.img` as an NTFS drive | PENDING-OWNER | Controller type, Disk Management/drive listing, label and size |
| Windows `chkdsk X: /scan` | PENDING-OWNER | Full output and exit status on the disposable copy |
| macOS 26 VM boots | PENDING-OWNER | Restore/guest build, desktop boot confirmation |
| macOS 26 sees virtual fixture disk | PENDING-OWNER | `diskutil list` and `diskutil info` output |
