# Prompt za provjeru Luxstream postave

Zalijepi sve ispod ovoga u Claude Code na VM-u koji provjeravaš.
Radi kao **provjera, ne popravak** — ništa ne mijenja dok mu ne kažeš.

---

Provjeri Luxstream postavu na ovom VM-u i izvijesti me po kategorijama u tablici.

**Ovo je provjera, ne popravak. Ne mijenjaj ništa dok ti izričito ne kažem.**
Ako nađeš kvar, opiši ga i predloži popravak — ali ne izvodi ga.

## Što je ovo

Hyper-V gost s **GPU-P particijom** RTX 4090. Streaming ide preko zakrpanog Sunshinea
(fork `VjekoslavDugec/Luxstream`) i Moonlighta. Paket je u `C:\Program Files\Luxstream`,
dokumentacija u `INSTALACIJA.md`, `README.md`, `TODO.md`, `RADNA-POSTAVA.md`.

## Kategorije, s očekivanim vrijednostima

| # | Kategorija | Očekivano | Čime provjeriti |
|---|---|---|---|
| 1 | GPU-P particija | uređaj `VEN_1414&DEV_008E`, status OK | `Get-PnpDevice -Class Display` |
| 2 | NVIDIA driver u gostu | mapa `nv_dispi.inf_amd64_*` postoji | `C:\Windows\System32\HostDriverStore\FileRepository` |
| 3 | Hyper-V Video adapter | prisutan, status OK | `Get-PnpDevice -FriendlyName 'Microsoft Hyper-V Video'` |
| 4 | **Displayi** | **DVA**; sporedni je Hyper-V zaslon (mala razlucivost, ovisi o VM-u) i stoji **dolje-desno**; virtualno ishodište **(0,0)** | `scripts\list-displays.ps1`, `SystemInformation::VirtualScreen` |
| 5 | **Vulkan** | **1 uređaj, GeForce RTX 4090**, API 1.4.x | `scripts\vulkantest.ps1` |
| 6 | **OpenGL** | `4.6.0 NVIDIA` — **NE** `GDI Generic` / `1.1.0` | `scripts\gltest.ps1` |
| 7 | Direct3D 12 | hardverski uređaj na RTX 4090 | `scripts\whichgpu.ps1` |
| 8 | VDD konfiguracija | `<friendlyname>` = NVIDIA GeForce RTX 4090, **11** `<resolution>` | `C:\VirtualDisplayDriver\vdd_settings.xml` |
| 9 | Sunshine proces | radi, `MainWindowHandle = 0` (skriven) | `Get-Process sunshine` |
| 10 | Sunshine potpis | `Valid`, `CN=Luxstream Code Signing` | `Get-AuthenticodeSignature` |
| 11 | UIAccess | token procesa `UIAccess = 1` | `GetTokenInformation`, `TokenUIAccess = 26` |
| 12 | Sunshine config | `capture = wgc`, `dd_configuration_option = verify_only`, bez BOM-a | `C:\Program Files\Sunshine\config\sunshine.conf` |
| 13 | Enkoder | NVENC (`hevc_nvenc` / `av1_nvenc`) | `sunshine.log` |
| 14 | Sparivanje | broj klijenata > 0 | `sunshine_state.json` |
| 15 | UAC | `ConsentPromptBehaviorAdmin = 5`, `PromptOnSecureDesktop = 0` | `HKLM\...\Policies\System` |
| 16 | Zadaci | `SunshineUser`, `StreamReady`, `RestoreConsoleSession`, `VerifyAfterBoot` | `Get-ScheduledTask` — **`RestoreConsoleSession` radi kao SYSTEM i NEVIDLJIV je iz nepovišene sesije**; ako ga ne vidiš, provjeri iz povišene prije nego javiš kvar |
| 17 | Okidači StreamReady | **dva** okidača, ponavljanje **samo na jednom**, `NextRunTime` popunjen | `(Get-ScheduledTask).Triggers` |
| 18 | Pokretanje bez bljeska | `SunshineUser` i `StreamReady` idu preko `wscript.exe` | `(Get-ScheduledTask).Actions[0].Execute` |
| 19 | Automatska prijava | `AutoAdminLogon = 1`, `DefaultPassword` **nije** u registryju | `scripts\postavi-auto-prijavu.ps1 -Provjeri` |
| 20 | Gamepad | uređaj s **hardverskim ID-om** `Nefarius\ViGEmBus\Gen1`; instance ID je `ROOT\SYSTEM\000x`, a prijateljsko ime *Nefarius Virtual Gamepad Emulation Bus* — u imenu **nema** niza „ViGEm" | `DEVPKEY_Device_HardwareIds`, `Get-Service ViGEmBus` |
| 21 | Identitet | pečat = `BIOS_UUID\|IME` i poklapa se sa strojem | `C:\Users\Public\luxstream-identity.txt` |
| 22 | Paket | ugrađena kopija = izvorni paket | usporedi kontrolne sume — razlika u `INSTALL.*` znači samo da je VM instaliran starijom verzijom, nije kvar postave |
| 23 | Padovi | `DuplicateOutput 0`, `Fatal 0` | `sunshine.log` |

Uz to pročitaj **`C:\Users\Public\priming-dijagnostika.log`** — watchdog ondje zapisuje
`displayi=` i `vulkan=` u tri točke svakog ciklusa. To je najbrži uvid u to drži li grafika.

## Zamke — pročitaj prije nego išta zaključiš

Ovo su greške koje su nas već koštale. Ne ponavljaj ih.

**Vulkan mjeri DVAPUT.** Pad nakon promjene topologije je **odgođen 13–32 s**. Mjerenje
odmah nakon promjene pokazuje `1` iako će za pola minute biti `0`. Izmjeri, pričekaj
~30 s, izmjeri opet.

**Dva displaya su NAMJERNA.** Hyper-V display mora ostati aktivan — bez njega Vulkan i
OpenGL ne prežive. Ako vidiš jedan display, **to je kvar, ne uredno stanje**. DirectX radi
u oba slučaja pa nije pokazatelj.

**Ne pokreći priming više puta.** Ponovljeni ciklusi degradiraju display stog do stanja u
kojem `SetDisplayConfig` više ne diže Hyper-V display. Tada pomaže samo restart VM-a.
Ako priming jednom ne uspije — stani i javi, ne ponavljaj.

**`query user` i konzola.** Ne pitaj postoji li konzolna sesija nego jesi li **ti** na
njoj — tekuću sesiju označava `>` na početku retka. Preko RDP-a su displayi drugi i sva
mjerenja grafike su bezvrijedna.

**Rezervirana imena u PowerShellu.** `$pid` je zauzet. Varijable nisu osjetljive na
veličinu slova, pa `foreach ($s in ...)` pregazi `$S`. Oboje nas je već koštalo.

**BOM.** `sunshine.conf` **ne smije** imati BOM — Sunshine tiho ignorira prvi ključ.
`.ps1` **mora** imati BOM, inače ga PowerShell 5.1 čita kao ANSI.

**Manifest se čita iz djeteta.** Čitanje ugrađenog manifesta u istom procesu koji ga je
mijenjao vraća keširanu staru vrijednost.

**Ne javljaj kvar iz ograničenja vlastite sesije.** Ako nisi povišen, `schtasks` i
`Get-ScheduledTask` neće vidjeti zadatke koji rade kao SYSTEM, a `Get-FileHash` neće moći
čitati iz `C:\Program Files\Sunshine\config\credentials`. To je „ne mogu izmjeriti" (❓),
ne „ne postoji" (❌).

**Razlučivost sporednog zaslona nije kriterij.** Hyper-V display ima različit zadani mod
od VM-a do VM-a (640×480, 1024×768…). Bitno je da ih ima **dva**, da je sporedni
**dolje-desno** i da je virtualno ishodište **(0,0)**.
**`Screen::AllScreens` se kešira po procesu.** Nakon promjene topologije pokreni
`list-displays.ps1` kao **svjež proces**.

## Kako izvijestiti

Tablica: kategorija | ✅/❌/❓ | izmjerena vrijednost.

Za svako ❌ napiši **što si točno izmjerio** i koja je najvjerojatnija pojedinačna
uzročna hipoteza — bez zaključivanja iz jednog mjerenja. Ako nemaš dovoljno podataka,
napiši ❓ i koje mjerenje nedostaje.

Na kraju jedna rečenica: je li postava u redu za rad ili nije.
