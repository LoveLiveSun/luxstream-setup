# Luxstream

Sunshine game streaming on a Hyper-V guest with a **GPU-P** (paravirtualised GPU)
partition — with native Vulkan, OpenGL and Direct3D, hardware NVENC, and a
one-click installer.

Verified working on Windows 10 Enterprise LTSC 2021 (19044), RTX 4090 shared from
the host via `Add-VMGpuPartitionAdapter`.

---

## The problem this solves

Sunshine does not work on a GPU-P guest out of the box. The paravirtual display
adapter **does not implement the Desktop Duplication API**, so capture fails before
it starts:

```
IDXGIOutput1::DuplicateOutput()  ->  0x80070057   (E_INVALIDARG)
```

No amount of changing topology, monitor count or primary display fixes this. It is
architectural.

**But Windows.Graphics.Capture works.** WGC goes through DWM rather than the display
driver, and captures exactly what Desktop Duplication cannot. Measured on the same
output at the same moment:

```
IDXGIOutput1::DuplicateOutput()          ->  0x80070057
GraphicsCaptureItem CreateForMonitor()   ->  S_OK, frames flowing
```

Sunshine already ships a complete WGC backend — but every output is filtered through
a Desktop Duplication probe first, so WGC never gets a chance. **One patch removes
that gate when `capture = wgc` is set explicitly.**

Patches live in the fork [`VjekoslavDugec/Luxstream`](https://github.com/VjekoslavDugec/Luxstream):

| Commit | What it does |
|---|---|
| `5247ed93` | do not gate outputs behind the Desktop Duplication probe when `capture=wgc` |
| `09e108f8` | do not let WinRT activation failures crash the process |
| `8f3c1676` | log each WGC init step and initialise the WinRT apartment |

The first is the actual fix. The others made the diagnosis possible.

---

## What you get

| | |
|---|---|
| Streaming | 5120×1440 @ 60 fps, HEVC, hardware NVENC, ~10 ms latency |
| Decode on client | ~1.5 ms |
| Vulkan | 1.4.x, native NVIDIA |
| OpenGL | 4.6, native NVIDIA |
| Direct3D 12 | native, full VRAM |
| Host CPU | ~5 % while streaming |

---

## Requirements

Two things the installer **cannot** do for you, because they happen outside the guest:

1. **GPU-P partition assigned to the VM**, on the host:
   `Add-VMGpuPartitionAdapter` — see `host/gpu-p-setup.ps1`
2. **NVIDIA driver copied into the guest**, into
   `C:\Windows\System32\HostDriverStore\FileRepository\nv_dispi.inf_amd64_*`
   With GPU-P the driver is *copied*, not installed, and must be the **same version**
   as on the host.

Preflight checks both and stops before changing anything if either is missing.

---

## Install

Download `Luxstream.exe` from the release and double-click it. That is the whole
procedure — it extracts to `C:\Luxstream-setup` and runs the installer.

**Run it from the Hyper-V console in Basic Session**, not through Enhanced Session
or RDP. Both of those give the VM their own temporary display, so the real displays
cannot be configured. The installer detects this and refuses to continue silently.

During the install:

- the screen briefly goes blank while the virtual display starts — expected
- when it finishes, in Basic Session you will **see** the desktop but not be able to
  **control** it. That is the signal that it worked: the primary display is now the
  virtual one. Switch to Enhanced Session or RDP to finish pairing.

The installer is **idempotent** — running it again skips everything already done.

---

## What it configures

| Phase | |
|---|---|
| 0 | preflight: elevation, session type, GPU-P partition, NVIDIA driver, Hyper-V adapter |
| 0b | copies itself to `C:\Program Files\Luxstream` and registers tasks from there |
| 1 | drivers: Virtual Display Driver, ViGEmBus, VB-Audio — including signer import |
| 2 | VDD configuration: bound to the NVIDIA GPU, 11 verified resolutions |
| 3 | patched Sunshine, and verifies the build really contains the patches |
| 4 | discovers the VDD display GUID from the log, writes `sunshine.conf` |
| 5 | four scheduled tasks |
| 6 | DPI, Game Bar, **UIAccess**, automatic logon, UAC |
| 7 | graphics priming and verification |

### Why scheduled tasks and not a service

Sunshine **cannot run as a service.** As SYSTEM it cannot activate
Windows.Graphics.Capture — `GraphicsCaptureSession::IsSupported()` throws
`std::bad_alloc`, which is how C++/WinRT surfaces the `E_OUTOFMEMORY` returned by
`RoGetActivationFactory` in that context. It is a Windows limitation, not a Sunshine
bug, and it cannot be configured away. So Sunshine runs as the logged-on user, which
is why **automatic logon is mandatory**.

### Two displays, on purpose

The Hyper-V display stays **active**. Without it, native Vulkan and OpenGL do not
survive — measured on a clean boot, they die 13–32 s after it is deactivated.
Direct3D works either way, so it is not a useful indicator.

The secondary display sits diagonally below-right of the primary, so the virtual
desktop origin stays at `(0,0)` (otherwise new desktop icons land on it) and the two
share no edge, so the mouse cannot wander across. A watchdog keeps it there and
brings back any window or icon that ends up on it.

### UIAccess

Without it a UAC prompt is **visible but not clickable** over the stream:
`consent.exe` runs at System integrity, Sunshine at High, and UIPI blocks the input.
The installer gives Sunshine `uiAccess="true"` and signs it, which is the mechanism
Windows provides for exactly this — the same one the on-screen keyboard uses.

Requires `PromptOnSecureDesktop = 0` as well, otherwise Windows switches to a desktop
WGC cannot see and the picture freezes.

---

## Verify

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Program Files\Luxstream\scripts\brza-provjera.ps1"
```

For a full audit across 23 categories, paste `PROVJERA-prompt.md` into an AI assistant
on the machine — it includes the traps that produce false conclusions.

---

## Client settings (Moonlight)

| Setting | Value | Why |
|---|---|---|
| Video decoder | **Automatic** | `Force software decoding` raises decode from ~1.5 ms to ~190 ms |
| Video codec | **HEVC** | `Automatic` would pick AV1 |
| Resolution | one from the VDD list | a mode not in the list is silently ignored |

---

## Known limitations

- **Gamepad is untested** with a real controller. ViGEmBus installs and is healthy;
  `x360` and `ds4` profiles should work. Exotic profiles need `libvirtualhid`, which
  will not bind (`UpdateDriverForPlugAndPlayDevices` fails with Win32 87).
- **Concurrent NVENC session limit across cloned VMs is unmeasured.**
  `scripts/nvenc-sesije.ps1` can measure it once a second VM exists.
- **Repeated priming degrades the display stack** until `SetDisplayConfig` stops
  activating the Hyper-V display. Only a reboot recovers it. The watchdog has a brake
  for this; do not run priming in a loop by hand.

---

## Cloning a VM

Copy the whole VM and it fixes itself on first logon — no reinstall. The scheduled
task detects the clone by BIOS UUID and rotates what must not be shared: TLS
certificate, `uniqueid`, `output_name` and the advertised host name. The old identity
is moved aside, not deleted.

**All clients must then be paired again.** That is deliberate.

---

## Credits and licences

| Component | Licence |
|---|---|
| [Sunshine](https://github.com/LizardByte/Sunshine) (patched) | GPL-3.0 |
| [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver) | see upstream |
| [ViGEmBus](https://github.com/nefarius/ViGEmBus) | see upstream |
| [VB-Audio Virtual Cable](https://vb-audio.com/Cable/) | see upstream |
| [Moonlight](https://github.com/moonlight-stream/moonlight-qt) (client) | GPL-3.0 |

Exact verified versions are listed in `installers/README.md`.
