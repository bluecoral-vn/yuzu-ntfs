<p align="center">
  <img src="docs/brand/origami/yuzu-ntfs/export/macos/AppIcon.appiconset/icon_256x256.png" width="128" alt="Yuzu NTFS icon">
</p>

<h1 align="center">Yuzu NTFS</h1>

<p align="center"><b>Use Windows (NTFS) drives on your Mac — just plug in.</b><br>
macOS 26+ · Apple silicon · <b>Beta 0.1</b></p>

---

Your Mac can open a Windows-formatted drive but can't save anything to it. Yuzu NTFS adds full NTFS support to macOS, so the drive works in Finder like any other disk.

## What you can do

| | |
|---|---|
| 🔌 **Plug in and go** | NTFS drives mount automatically in Finder. No Terminal, no extra steps. |
| ✏️ **Read and write** | Copy, save, rename and delete files on drives that come from Windows PCs. |
| 🛡️ **Your data comes first** | If Windows didn't shut down cleanly (Fast Startup, hibernation) or the drive needs checking, it opens **read-only** and Yuzu NTFS tells you why and how to fix it. Nothing is changed behind your back. |
| 🔒 **Keeps your Mac secure** | No kernel extension, no Recovery Mode, no lowering security settings, no restart. Uninstall by dragging the app to the Trash. |
| ⚡ **Fast** | File data moves straight between the drive and macOS, so copies run close to the drive's own speed. |
| 🪟 **Windows-friendly** | Names, folders, links and Mac file info are stored in ways Windows understands. No `._` clutter files. |
| 🍋 **Lives in the menu bar** | See every NTFS drive, whether it can be written, and eject it in one click. |

## How to use

1. Open the app and turn on **Yuzu NTFS** when asked (one time only).
2. Plug in your NTFS drive.
3. Use it in Finder. When you're done, eject as usual.

> **Beta note:** writing is still being tested. In this beta, drives open **read-only** so your files stay safe. Keep a backup of anything you can't replace.

**Good to know:** encrypted (BitLocker) drives and formatting disks as NTFS aren't supported. For a brand-new disk shared between Mac and Windows, exFAT is the simplest choice.

## More from Yuzu Apps

Small, private Mac apps from [**yuzu.today**](https://yuzu.today) — no account, no tracking.

| App | What it does |
|---|---|
| [**Yuzu Drag**](https://yuzu.today/drag/) | Convert, compress and share files just by dragging them. |
| [**Yuzu Clipboard**](https://yuzu.today/clipboard/) | Find anything you copied — text, links, images and files. |
| [**Yuzu Shot**](https://yuzu.today/shot/) | Capture, annotate and save screenshots. |
| [**Yuzu Awake**](https://yuzu.today/awake/) | Keep your Mac awake for as long as you need. |
| [**Yuzu MagicMenu**](https://yuzu.today/magic-menu/) | New File, Move To and Copy To in Finder's right-click menu. |
| [**Yuzu Sum**](https://yuzu.today/sum/) | A notepad calculator: answers appear as you type. *Coming soon.* |
| [**Yuzu Sync**](https://yuzu.today/sync/) | Keep folders in sync across your Mac, external disks and NAS. *Coming soon.* |

---

<sub>Free and open source under the [GNU GPL v2](LICENSE). Made by Blue Coral. Developers: see [docs/development.md](docs/development.md).</sub>
