# Grafika u Hyper-V GPU-P gostu

**Provjereno 21.8.2026.** na VM-u `GPU-test`, Windows 10 LTSC 19044, RTX 4090 preko GPU-P.

Prethodna verzija ovog dokumenta tvrdila je da izvorni Vulkan i OpenGL ne rade i da
treba Mesa. **To je bilo krivo** i cijeli je dokument zato prepisan. Stara verzija je
zadržana kao `GRAFIKA.md.zastarjelo`.

---

## 1. Sažetak

Sve tri grafičke API-je rade **izvorno**, na pravom NVIDIA driveru:

```
Vulkan       NVIDIA GeForce RTX 4090   API 1.4.325   Discrete GPU
OpenGL       NVIDIA GeForce RTX 4090/PCIe/SSE2   4.6.0 NVIDIA 591.59
Direct3D 12  feature level 12_0,  24138 MiB
NVENC        h264_nvenc, hevc_nvenc, av1_nvenc     hardverski
```

Mesa nije potrebna ni za što — ni `d3d12` za OpenGL, ni Dozen za Vulkan.

**Jedini uvjet:** Hyper-V synthetic display mora biti prikačen na desktop.

---

## 2. Zašto Hyper-V display mora ostati

Ovo je jedina prava zamka i vrijedi je razumjeti, jer se inače ne da pogoditi.

NVIDIA-in ICD — i za Vulkan i za OpenGL — nabraja fizičke uređaje tek kad postoji
**NVIDIA-in WDDM display put**. Bez njega:

```
Vulkan : 0 uredaja  (loader radi, ICD javi praznu listu)
OpenGL : GDI Generic 1.1.0
```

Virtual Display Driver **to ne rješava**, čak ni kad je u `vdd_settings.xml` vezan na
`NVIDIA GeForce RTX 4090`. VDD je indirektni display (IddCx): renderira na 4090, ali
ne stvara display put koji ICD traži. Izmjereno, nije pretpostavka.

Taj put daje **isključivo Hyper-V synthetic display**.

### Praktična postava

```
VDD (ROOT\DISPLAY\0000)   5120x1440 @ 60 Hz   primary   <- ovo se streama
Hyper-V synthetic          640x480  @ 64 Hz             <- samo da ICD bude zadovoljen
```

Hyper-V display je najmanji mogući i položen na `-640,1080`, dakle dijagonalno ispod
lijevog ruba glavnog. Tako se s glavnim dodiruje **u jednoj jedinoj točki**, a Windows
za prijelaz kursora traži preklapajući odsječak ruba — pa miš ne može odlutati na njega.
Windows ne dopušta ni potpuno odvojen display, pa je ovo najmanji mogući dodir.

### Prikačivanje ne ide preko DisplaySwitch

`DisplaySwitch.exe /extend` na ovom sustavu **tiho ne uspije** — ne javi grešku, ali
ne napravi ništa. Izravan poziv radi:

```
SetDisplayConfig(0, NULL, 0, NULL, SDC_APPLY | SDC_TOPOLOGY_EXTEND)   -> rc = 0
```

To je u `scripts\ensure-streaming-ready.ps1`, koji se vrti kao zadatak `StreamReady`
svake minute i vraća display ako nestane. Bez njega se nakon ponovnog pokretanja
Hyper-V display ne prikvači sam.

### Sunshine ga ne smije izbaciti

`dd_configuration_option` mora biti **`verify_only`**.

S `ensure_active` Sunshine pri pokretanju streama postavi topologiju na samo VDD i
izbaci Hyper-V display. Posljedica je izmjerena uživo: Cemu je pao usred pokretanja
Zelde jer mu je Vulkan nestao petnaest sekundi ranije.

Cijena `verify_only` je da `dd_resolution_option = auto` ne djeluje, pa se rezolucija
desktopa postavlja ručno.

---

## 3. Što više NIJE potrebno

Ovo je nekad bilo u uputama i sad je suvišno.

### Prebacivanje primarnog displaya na Hyper-V

Nekad je izvorni OpenGL tražio da Hyper-V display bude **primaran**, zbog čega je miš
bježao i slika se selila. Otkad je VDD u `vdd_settings.xml` vezan na
`NVIDIA GeForce RTX 4090`, primaran je VDD a OpenGL svejedno bira NVIDIA ICD.

### `launch-with-native-gpu.ps1`

Aplikacije se pokreću normalno, dvoklikom. Nema odbrojavanja, nema prebacivanja
primarnog displaya, nema odspajanja monitora nakon pokretanja.

Sama skripta uz to ima grešku: provjerava je li Hyper-V monitor prikačen gledajući
`WmiMonitorID`, a taj popis ga izlista **i kad nije u topologiji desktopa**. Provjera
zato daje lažno pozitivno i skripta preskoči prikačivanje. Zadržana je kao povijesna.

### Mesa (d3d12, llvmpipe, zink, Dozen)

Ništa od toga ne treba. Za usporedbu, dokle se stizalo prije:

```
Mesa d3d12   OpenGL 4.2        izvorni NVIDIA daje 4.6
Mesa Dozen   Vulkan 1.2        izvorni NVIDIA daje 1.4.325
llvmpipe     OpenGL 4.6 softverski
zink         ne radi ("failed to choose pdev")
```

Mesa je i dalje instalirana u `C:\Mesa`, a njen Dozen je jedini upisan u
`HKLM\SOFTWARE\Khronos\Vulkan\Drivers`. Ne smeta, ali se ne koristi.

---

## 4. Gdje su NVIDIA-ine biblioteke

Kod GPU-P-a se driver **kopira**, ne instalira. Zato u registru nema uobičajenih zapisa:

```
HKLM\SOFTWARE\Khronos\Vulkan\Drivers        samo Mesa Dozen, NVIDIA nije upisana
OpenGLDriverName / VulkanDriverName         prazno na svih 12 adaptera
Control\Video                               nijedan zapis
```

A datoteke postoje:

```
C:\Windows\System32\HostDriverStore\FileRepository\nv_dispi.inf_amd64_4646b47d9477048e\
    nv-vk64.json      Vulkan ICD manifest, api_version 1.4.325
    nvoglv64.dll      OpenGL i Vulkan ICD
```

Loader ih nalazi preko **D3DKMT-a** — pita kernel driver za putanje po adapteru — a ne
preko registra. To ujedno objašnjava zašto display mora biti prikačen: bez NVIDIA-inog
display puta D3DKMT nema takav adapter za prijaviti.

### Ručna registracija ICD-a ne pomaže — izmjereno

Upis `nv-vk64.json` u `HKLM\SOFTWARE\Khronos\Vulkan\Drivers` loader **stvarno prihvati**:
s prikačenim Hyper-V displayem Vulkan tada nabroji **dva** uređaja, isti 4090 dvaput.
Ali bez Hyper-V displaya i dalje javi **nula**.

Brana dakle nije u tome kako loader nalazi ICD, nego je **unutar samog ICD-a** — on
pita kernel driver za fizičke uređaje i dobije prazno. Registracija je vraćena jer
dvostruko nabrajanje istog GPU-a nije bezopasno; aplikacija lako uzme drugi primjerak.

---

## 5. Provjera

```powershell
.\scripts\vulkantest.ps1     # ocekuj: NVIDIA GeForce RTX 4090, API 1.4.325
.\scripts\gltest.ps1         # ocekuj: 4.6.0 NVIDIA 591.59
.\scripts\d3d12test.ps1      # ocekuj: feature level 12_0, 24138 MiB
```

Ako Vulkan javi 0 uređaja a OpenGL `GDI Generic`, prvo provjeri broj displaya:

```powershell
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Screen]::AllScreens.Count    # mora biti 2
```

Ako je 1, Hyper-V display je otpao. Pokreni `ensure-streaming-ready.ps1` ili zadatak
`StreamReady`.

---

## 6. High performance GPU za aplikacije

I dalje vrijedi. Aplikacija koja ne traži izričito diskretni GPU može završiti na
Microsoft Basic Render Driveru.

```powershell
$k='HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
New-Item -Path $k -Force | Out-Null
Set-ItemProperty -Path $k -Name 'C:\put\do\App.exe' -Value 'GpuPreference=2;'
```

---

## 7. Zamke

**Ne gasi Hyper-V Video adapter.** Ostaješ bez Vulkana i OpenGL-a.

**Ne otvaraj VDD Control.** Prepiše `vdd_settings.xml` svojim predloškom i obriše
`<count>` i `<friendlyname>`.

**Ne mijenjaj `dd_configuration_option` s `verify_only`.** Vidi poglavlje 2.

**Ne piši konfiguraciju s BOM-om.** `Set-Content -Encoding UTF8` i `Out-File -Encoding utf8`
na PowerShellu 5.1 dodaju BOM, pa Sunshine prvi ključ pročita kao `\ufeffcapture` i tiho
ga ignorira. Koristi:

```powershell
[System.IO.File]::WriteAllLines($put, $redci, (New-Object System.Text.UTF8Encoding($false)))
```

**Dijalog "Keep these display settings?"** pojavi se na novom primarnom monitoru koji se
ne vidi i nakon 15 sekundi sve poništi. Promjene displaya raditi programski.

**Hyper-V VM postavke mijenjati samo PowerShellom.** Hyper-V Manager GUI ne poznaje GPU
particijske adaptere, tiho ih izbaci, i uz to vrati `AutomaticStopAction` na `Save` i
`CheckpointType` na `Standard` — oboje ubija GPU-P.

**PowerShell ne razlikuje velika i mala slova u imenima varijabli.** `foreach ($s in ...)`
pregazi `$S`. Pojelo nam je dva pokušaja.

---

## 8. Ograničenja koja ostaju

**Sunshine ne može raditi kao servis.** Servis ga pokrene kao SYSTEM, a WinRT aktivacija
`GraphicsCaptureItem` za SYSTEM ne prolazi i proces se ubije s `0xc0000409`. Radi kao
`luxnet` preko zadatka `SunshineUser`. Posljedica: diže se tek nakon prijave i ne hvata
zaslon za prijavu.

**Rezolucija desktopa se postavlja ručno**, zbog `verify_only`.

**Desktop Duplication ne radi** i nikad neće — `0x80070057` na svakom izlazu. Zato
`capture = wgc` i zakrpani Sunshine. Znači i da nijedan drugi alat koji se oslanja na
DDA neće raditi: Parsec, RustDesk, OBS *Display Capture*. OBS-ov *Window Capture (WGC)*
bi trebao proći.
