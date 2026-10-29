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

Patches live in the fork [`VjekoslavDugec/Sunshine-wgc`](https://github.com/VjekoslavDugec/Sunshine-wgc):

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
| Clipboard &amp; files | text, images and files both ways, outside the stream protocol |

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
  virtual one. Switch to Enhanced Session or RDP so you can operate the VM and click
  the host in Moonlight — pairing then completes on its own, with no PIN.

The installer is **idempotent** — running it again skips everything already done.

### Pairing and the Sunshine web UI

Both sides of the pairing handshake are patched to use one fixed PIN, so **pairing is
automatic**. Add the VM in Moonlight by IP, click it, and it pairs — there is no
four-digit code to carry from Moonlight into the host, and no PIN dialog in Moonlight.
Pairing is permanent; afterwards you just click and connect.

> Pair only with the Moonlight build shipped alongside this setup. The stock Moonlight
> from the stores still asks for a PIN and will not pair by itself.

The Sunshine web UI (`https://<host-ip>:47990`) has **no login**. The browser will warn
about the certificate — that is expected, Sunshine signs it itself; pick *Advanced* →
*Continue*. You only need the UI to change encoder or display settings, or to see which
clients are paired.

> Anyone who can reach port 47990 gets straight in. Keep this VM on an isolated network.

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
| 5 | five scheduled tasks |
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

## Clipboard and file transfer (host &lt;-&gt; VM)

**Sunshine and Moonlight share neither clipboard nor files.** This is not a missing
setting — the streaming protocol has no such feature. `sunshine.exe` contains no
reference at all to the Windows clipboard API (`OpenClipboard`, `SetClipboardData`,
`CF_UNICODETEXT` are all zero). RDP has it because RDP is a remote *desktop* protocol
with virtual channels; Moonlight carries only picture, sound and input.

> **Do not solve this with a parallel RDP session.** RDP moves the console session to
> itself, the VDD disappears and Sunshine is left with no picture.

`scripts\luxstream-bridge.ps1` fills the gap **outside** the stream protocol, over plain
TCP, so it works with any Sunshine and Moonlight version:

| What | How |
|---|---|
| text | copy on one side, paste on the other |
| image (PNG) | same, through the clipboard |
| **file copied in Explorer** | Ctrl+C on a file, Ctrl+V on the other side pastes the file itself |
| **file via a folder** | drop it into `%USERPROFILE%\Luxstream\Drop\`; it leaves that folder and appears in `Luxstream\Primljeno\` on the other side |

### Host listens, VM connects

The host on the *Default Switch* has a **fixed** address (`172.29.32.1`); a VM's address
changes (DHCP, clones), so it would have to be rewritten on the host constantly. A client
without `-Peer` simply uses the default gateway — which on the Default Switch is the host.

On the **host**, once, from an elevated PowerShell:

```powershell
New-NetFirewallRule -DisplayName 'Luxstream bridge' -Direction Inbound `
  -Protocol TCP -LocalPort 51888 -Action Allow -RemoteAddress 172.29.32.0/24

.\scripts\luxstream-bridge.ps1 -Mode Server -Install
```

`-Install` writes `C:\ProgramData\Luxstream\bridge.json`, generates a shared secret,
prints it and registers the `LuxstreamBridge` task at logon. The installer in the VM
already registers the client half; pass the host's secret to it so both sides match:

```powershell
.\INSTALL.ps1 -TajnaMosta 'secret-from-the-host'
```

(Without it the installer generates its own and prints a ready-made host command at the
end.) Manual equivalent on the VM:

```powershell
.\scripts\luxstream-bridge.ps1 -Mode Client -Secret '<secret-from-the-host>' -Install
```

**Do not run it as a Windows service** — a service lives in session 0, where the user's
clipboard is invisible.

### Check it

```powershell
# is it running, what is configured, last 15 log lines
.\scripts\luxstream-bridge.ps1 -Status

# self-test with no outside connection - real TCP on 127.0.0.1: text with
# diacritics both ways, a PNG, a 700 KB file crossing the 256 KB chunk
# boundary (MD5), and name sanitising
.\scripts\luxstream-bridge.ps1 -SelfTest
```

Log: `%USERPROFILE%\Luxstream\luxstream-bridge.log`. It also records **why the bridge did
not start** (missing secret, for instance) — otherwise a failure inside a hidden
scheduled task would be completely silent.

### Limitations

- Traffic is **not encrypted**. The shared secret only prevents accidental connections.
  Intended for a trusted LAN.
- Folders are **not sent recursively** — files only. Archive a folder, or copy into
  `Drop\` in several passes.
- Caps: text 1 MB, image 16 MB, 64 MB total per clipboard file group, 4 GB per `Drop\`
  file, 64 MB per frame.
- Names are sanitised (any path stripped, `<>:"|?*` and control characters become `_`,
  truncated to 180 chars); collisions get a `-1`, `-2`… suffix.
- It needs an **interactive session**. As a service it does nothing — silently.

---

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
