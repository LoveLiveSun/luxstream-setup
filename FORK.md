# Vlastiti Sunshine za GPU-P: fork, zakrpa, build

**Stanje:** zakrpa je napisana, testirana protiv trenutnog upstream koda i commitana
lokalno u `C:\Users\Public\sunshine-fork\Luxstream`.
Datoteka zakrpe: `C:\Users\Public\sunshine-fork\wgc-gpup.patch`

---

## 1. Zašto uopće fork

Sunshine **već ima kompletan Windows.Graphics.Capture backend** — `display_wgc.cpp`,
`wgc_capture_t`, `display_wgc_ram_t`, `display_wgc_vram_t`. Ne piše se ništa novo.

Problem je čisto redoslijed provjera. U `src/platform/windows/display_base.cpp`
svaki se izlaz propušta kroz `test_dxgi_duplication()` na dva mjesta:

| linija | funkcija | posljedica pada |
|---|---|---|
| 514 | `display_base_t::init()` | `output` se ne odabere, pa `wgc_capture_t::init()` nikad ne dođe do `CreateForMonitor()` |
| 1111 | `display_names()` | display se ne pojavi u popisu, ni u web sučelju |

Na GPU-P gostu `IDXGIOutput1::DuplicateOutput()` pada s `0x80070057` (E_INVALIDARG)
na **svakom** izlazu i **svakom** adapteru, jer gostujući driver uopće nema
implementiran duplication put. Zato Sunshine kaže da nema displaya za hvatanje —
iako bi ga vlastitim WGC backendom mogao uhvatiti bez problema.

### Mjerenje koje to dokazuje

Isti display, ista sekunda, VDD vezan na NVIDIA GeForce RTX 4090:

```
OUTPUT 0: \.\DISPLAY65  1920x1080  attached=True
  IDXGIOutput1::DuplicateOutput()        -> FAIL 0x80070057
  GraphicsCaptureItem CreateForMonitor() -> OK,  'Display 1'  1920x1080
  Direct3D11CaptureFramePool + sesija    -> *** KADAR 1 *** 1920x1080
                                            *** KADAR 2 *** 1920x1080
```

Skripte kojima se to ponavlja: `scripts\ddtest.ps1` i `scripts\wgcframe.ps1`,
oboje odjednom preko `C:\Users\Public\test-wgc-on-nvidia.ps1`.

---

## 2. Što zakrpa mijenja

Jedna nova funkcija u `display_base.cpp` i dva poziva preusmjerena na nju:

```cpp
bool test_capture_supported(adapter_t &adapter, output_t &output, bool enumeration_only) {
  if (config::video.capture == "wgc") {
    return true;
  }
  return test_dxgi_duplication(adapter, output, enumeration_only);
}
```

Namjerno **samo** kod eksplicitnog `capture = wgc`. Ako `capture` nije postavljen,
ponašanje je bit po bit isto kao dosad — Desktop Duplication se i dalje prvo isproba.
Nitko drugi ne osjeti promjenu, pa zakrpa ima šansu proći i kao PR prema upstreamu.

Uz to ide `.github/workflows/build-windows-only.yml` — gradi **samo** Windows
instalater, na klik. Upstream `ci.yml` gradi i Docker, Flatpak, FreeBSD, macOS,
Linux i ARM64; na privatnom forku pola toga padne jer nema tajni repozitorija,
a cijeli krug traje satima.

---

## 3. Postupak korak po korak

### 3.1. Fork je napravljen

`https://github.com/VjekoslavDugec/Luxstream` — `master` stoji na `0a1c365`,
istom commitu protiv kojeg je zakrpa pisana.

### 3.2. Uključi Actions na forku

GitHub na forkovima **isključi** workflowe dok ih ručno ne odobriš.

1. Na forku otvori karticu **Actions**
2. Klikni **I understand my workflows, go ahead and enable them**

Bez ovog koraka gumb za build ne postoji.

### 3.3. Dodaj lokalni repozitorij u GitHub Desktop

Repozitorij je već kloniran, zakrpan i spojen na tvoj fork — nema potrebe
ponovno skidati 44 MB povijesti.

1. GitHub Desktop → **File** → **Add local repository**
2. Putanja: `C:SERSPUBLICSUNSHINE-FORKuxstream`
3. **Add repository**

Pokazat će `master`, jedan commit ispred `origin/master`, čisto radno stablo.

### 3.4. Push

Gore u GitHub Desktopu: **Push origin**. To je sve — commit je već napravljen.

Ako traži prijavu, odradi je **ti** u GitHub Desktopu.

### 3.5. Ako radije kloniraš sam

Alternativa, ako ti je draže čisto: **File** → **Clone repository** → `Luxstream`,
pa mi javi putanju i primijenim zakrpu ondje:

```bash
git apply --3way /c/Users/Public/sunshine-gpup-setup/wgc-gpup.patch
```

### 3.6. Pokreni build

1. Na forku → **Actions**
2. Lijevo **Build Windows only**
3. Desno **Run workflow** → **Run workflow**
4. Traje otprilike 40-60 minuta

### 3.7. Skini instalater

1. Otvori završeni run
2. Dolje **Artifacts** → **build-Windows-AMD64**
3. U zip-u je `Sunshine-Windows-AMD64-installer.msi`

MSI nije digitalno potpisan (Azure potpisivanje se na forku preskače), pa će
SmartScreen zacviliti — **More info** → **Run anyway**.

---

## 4. Konfiguracija nakon instalacije

Tek sad dolazi ono zbog čega je sve ovo rađeno. Cilj je da **svi** displayi budu
NVIDIA-ini, jer o tome ovise izvorni OpenGL i Vulkan.

### 4.1. VDD vrati na NVIDIA

`C:\VirtualDisplayDriver\vdd_settings.xml`:

```xml
<gpu><friendlyname>NVIDIA GeForce RTX 4090</friendlyname></gpu>
```

Zatim restart uređaja `ROOT\DISPLAY\0000` (u paketu: `scripts\01-vdd-configure.ps1`).

### 4.2. sunshine.conf

```
capture = wgc
```

Piši **bez BOM-a**, inače Sunshine prvi ključ pročita kao `ï»¿capture` i tiho ga ignorira:

```powershell
[System.IO.File]::WriteAllLines($p, $lines, (New-Object System.Text.UTF8Encoding($false)))
```

### 4.3. Provjeri NVENC

Ovo je moguća nagrada uz glavnu. Dosad je bilo `encoder = software` (libx264)
jer je hvatanje išlo preko WARP-a, koji nema enkoder. S WGC-om je uređaj za
hvatanje na NVIDIA adapteru, pa NVENC možda postane dostupan:

```
encoder = nvenc
```

Ako Sunshine u logu prijavi da NVENC probe pada, vrati na `software`. GPU-P ne
mora izlagati NVENC gostu — to se tek mora izmjeriti.

---

## 5. Očekivano konačno stanje

| API | prije | poslije |
|---|---|---|
| DirectX 11/12 | izvorni | izvorni |
| Vulkan | izvorni, ali traži prikačen Hyper-V monitor | izvorni |
| OpenGL | izvorni, ali traži Hyper-V monitor kao primarni | izvorni |
| Hvatanje slike | samo preko WARP displaya | WGC na NVIDIA displayu |
| Enkoder | libx264 softverski | za provjeriti NVENC |

Hyper-V monitor i dalje treba biti **prikačen** u trenutku pokretanja aplikacije
da NVIDIA-in ICD prijavi uređaj — to je odvojena pojava od hvatanja slike i
zakrpa je ne dira. Za to služi `scripts\launch-with-native-gpu.ps1`.

---

## 6. Ako build padne

Upstream gradi s `-DBUILD_WERROR=ON` — svako upozorenje prevoditelja ruši build.
Zakrpa je pisana s time na umu (nema neiskorištenih parametara, nema implicitnih
konverzija), ali ako ipak padne:

1. U Actions otvori pali posao, klikni **Build Windows** korak
2. Kopiraj mi zadnjih tridesetak redaka
3. Popravim, ti napraviš novi commit i push, i **Run workflow** ponovno

---

## 7. Prijedlog upstreamu

Kad zakrpa bude potvrđena u praksi, ima smisla otvoriti PR na LizardByte/Sunshine.
Argument je jak: koristi njihov postojeći backend, mijenja ponašanje isključivo uz
eksplicitni `capture = wgc`, i rješava cijelu kategoriju hostova — GPU-P/GPU-PV
gostovi, Hyper-V, a vjerojatno i neki hibridni prijenosnici gdje DDA pada iz
istog razloga.

Priloži im mjerenje iz poglavlja 1. To je ono što će ih uvjeriti.
