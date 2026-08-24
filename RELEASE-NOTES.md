# Luxstream v1.0.0

First public release. Sunshine streaming on a Hyper-V guest with a GPU-P partition,
with native Vulkan, OpenGL and Direct3D — installed in one click.

## Download

**`Luxstream.exe`** (~33 MB) — everything in one file. Double-click, and it extracts
to `C:\Luxstream-setup` and runs the installer.

> Run it from the **Hyper-V console in Basic Session**, not through Enhanced Session
> or RDP. The installer detects the wrong session type and tells you how to fix it
> rather than failing halfway.

## Requirements

Two steps happen outside the guest and must be done first:

1. GPU-P partition assigned to the VM — `Add-VMGpuPartitionAdapter`
2. NVIDIA driver **copied** into `C:\Windows\System32\HostDriverStore\FileRepository\`
   — same version as the host

Preflight checks both and stops before changing anything if either is missing.

## What is in it

- **Patched Sunshine** (`2026.821.103043`) with the Windows.Graphics.Capture fix
- Virtual Display Driver, ViGEmBus, VB-Audio
- Four scheduled tasks: streaming watchdog, hidden Sunshine launcher, session restore,
  post-boot verification
- UIAccess for Sunshine, so UAC prompts can be answered over the stream
- Automatic logon, DPI, Game Bar and UAC configuration
- Diagnostics: `brza-provjera.ps1` for a quick check, `PROVJERA-prompt.md` for a full
  23-category audit

## The core fix

The GPU-P paravirtual adapter does not implement Desktop Duplication, so Sunshine
fails with `0x80070057` before capture even starts. Sunshine already has a complete
WGC backend, but filters every output through a Desktop Duplication probe first, so
WGC never runs. One patch removes that gate when `capture = wgc` is explicit.

Fork: [`VjekoslavDugec/Luxstream`](https://github.com/VjekoslavDugec/Luxstream) —
commits `5247ed93`, `09e108f8`, `8f3c1676`.

## Measured

```
5120x1440 @ 60 fps, HEVC, hardware NVENC
decode on client   ~1.5 ms
latency            ~10 ms
host CPU           ~5 %
Vulkan 1.4.325  ·  OpenGL 4.6  ·  Direct3D 12, full VRAM
```

## Design decisions worth knowing

**Sunshine runs as a scheduled task, not a service.** As SYSTEM it cannot activate
Windows.Graphics.Capture. That is why automatic logon is mandatory.

**Two displays are intentional.** The Hyper-V display must stay active or native
Vulkan and OpenGL die within half a minute. It is parked diagonally below-right so
the desktop origin stays at `(0,0)` and the mouse cannot wander onto it.

**Cloning works without reinstalling.** A copied VM detects itself by BIOS UUID on
first logon and rotates its TLS certificate, `uniqueid`, `output_name` and host name.
Clients must be paired again.

## Known limitations

- Gamepad is not verified with a real controller
- Concurrent NVENC session limits across cloned VMs are unmeasured
- Repeated manual priming degrades the display stack until a reboot

## Documentation

`README-EN.md` for the overview, `INSTALACIJA.md` for the installer and every trap
built into it, `TODO.md` for what is still open and what was measured and rejected.
