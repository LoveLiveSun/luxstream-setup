# Instalacijski paketi

**Ne trebaš ovo čitati za normalno postavljanje.** Sve što je ovdje opisano radi
`INSTALL.cmd` iz korijena paketa. Ovaj dokument postoji zbog dvije stvari: da se zna
**točno koje verzije** su provjerene u radu, i da se paket može **rekonstruirati** bez
ovih binarnih datoteka (za objavu na GitHubu — vidi `DISTRIBUCIJA.md`, internu
bilješku koja nije u ovom repozitoriju).

> Stara verzija ovog dokumenta (`README.md.zastarjelo`, lokalna arhiva koja nije u
> repozitoriju) bila je netočna na dvije važne stavke: uputila je da se Sunshine
> instalira **kao servis** (ne može — SYSTEM ne može aktivirati WGC) i navodila je
> staru upstream verziju Sunshinea bez naših zakrpa.

---

## Provjerene verzije

| Komponenta | Verzija | Proizvođač | Licenca |
|---|---|---|---|
| Sunshine (zakrpani) | `2026.821.103043` | LizardByte, fork `VjekoslavDugec/Sunshine-wgc` | GPL-3.0 |
| Virtual Display Driver | `11.30.4.434` (2024-12-24) | MikeTheTech | provjeri u izvoru |
| ViGEmBus | `1.21.442.0` (2022-08-30) | Nefarius Software Solutions e.U. | provjeri u izvoru |
| VB-Audio Virtual Cable | `3.3.1.7` driver / `2.1.5.8` instalater | VB-Audio Software | **donationware, ograničena redistribucija** |
| Moonlight (klijent) | `6.1.0` | Moonlight Game Streaming Project | GPL-3.0 — **nije u paketu**, preuzmi na klijentu |

**Nijedna od tih datoteka nema priloženu licencu u ovom paketu.** Prije bilo kakve
javne objave to treba provjeriti u izvoru — osobito za VB-Audio, čiji uvjeti
redistribuciju instalatera ograničavaju.

---

## Izvori

| Komponenta | Odakle |
|---|---|
| Sunshine (zakrpani) | `Sunshine.exe` iz naše gradnje (gradi ga `build-windows-only.yml` u forku `VjekoslavDugec/Sunshine-wgc`); MSI može biti bilo koje izdanje Sunshinea |
| Virtual Display Driver | <https://github.com/VirtualDrivers/Virtual-Display-Driver> |
| ViGEmBus | <https://github.com/nefarius/ViGEmBus> |
| VB-Audio Virtual Cable | <https://vb-audio.com/Cable/> |
| Moonlight | <https://github.com/moonlight-stream/moonlight-qt/releases> — **ide na klijent, nije u paketu** |

---

## Što instalater radi s njima

| Mapa | Postupak |
|---|---|
| `vdd-driver` | uvoz potpisnika iz `.cat` → `pnputil /add-driver` → stvaranje root uređaja preko SetupAPI-ja |
| `vigembus` | isto; hardverski ID se čita iz INF-a (`Nefarius\ViGEmBus\Gen1`) |
| `vb-audio-cable` | `VBCABLE_Setup_x64.exe -i -h` (tiho) |
| `sunshine` | `msiexec /qn` (ako se verzija razlikuje), pa se `Sunshine.exe` preslika preko MSI-jevog |


Detalji i razlozi: `..\INSTALACIJA.md`.

---

## Sunshine: dva dijela, ne jedan

U `sunshine\` su **dvije** datoteke i obje moraju biti u paketu:

| Datoteka | Što je |
|---|---|
| `*.msi` | osnova: servis, skripte, `assets\`, firewall pravila, alati (`dxgi-info`, `audio-info`, `sunshinesvc`) |
| `Sunshine.exe` | **naš zakrpani binarni build**, koji `INSTALL.ps1` preslika preko onoga iz MSI-ja |

Zakrpa (WGC instrumentacija + WGC-only put bez Desktop Duplication probe) živi u
**`Sunshine.exe`**, a ne u MSI-ju. Zato MSI može biti i upstream izdanje — njegov
je `sunshine.exe` ionako zamijenjen. Ime MSI-ja nije važno: `INSTALL.ps1` uzima
prvi `*.msi` u toj mapi ako ne nađe `Luxstream-Sunshine-patched.msi`.

Zamjena je sigurna jer je naš build izravna zamjena za MSI-jev: isti MinGW UCRT64
toolchain, statički link, identična tablica uvoza (samo `api-ms-win-crt-runtime`
i `KERNEL32`). Prije kopiranja se `sunshine.exe` zaustavi, a usporedba po SHA256
znači da ponovno pokretanje instalatera ne prepisuje ništa.

> Zamjenu radi **faza 3**, dakle **prije** UIAccess faze (6) — potpis mijenja
> datoteku i mora se primijeniti na konačnu verziju.

Prije objave ovog paketa oba dijela treba `strip`-ati, kao što to radi
`CPACK_STRIP_FILES` u Sunshineovom pakiranju: 121 MB → ~72 MB, uz očuvan marker
`wgc: init start` koji instalater provjerava.

---

## Ručno, ako baš treba

```powershell
pnputil /add-driver "vdd-driver\mttvdd.inf" /install
pnputil /add-driver "vigembus\vigembus.inf" /install
```

`pnputil` sam **ne stvara** root-enumerirani uređaj — driver samo uđe u trgovinu.
Uređaj stvara instalater preko `SetupDiCreateDeviceInfo` + `DIF_REGISTERDEVICE` +
`UpdateDriverForPlugAndPlayDevices`. Ručna zamjena je
*Device Manager → Action → Add legacy hardware → Have Disk*.

VDD očekuje konfiguraciju baš na `C:\VirtualDisplayDriver\vdd_settings.xml`, i to s
najviše **11 rezolucija** — sa 17 je driver prestao prijavljivati monitor.

---

## Moonlight, na klijentu

| Postavka | Vrijednost | Zašto |
|---|---|---|
| Video decoder | **Automatic** | `Force software decoding` diže decode s 1,5 ms na 188 ms |
| Video codec | **HEVC** | `Automatic` bi izabrao AV1 |
| Rezolucija | jedna **iz VDD liste** | ostale se neće primijeniti |
| Bitrate | 50–80 Mbps na LAN-u | |

Provjereno u radu: **5120×1440 @ 60 fps**, HEVC, hardverski NVENC, decode 1,5 ms.
