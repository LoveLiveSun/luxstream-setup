# Objava na GitHubu — što ima smisla, a što ne

Kratak odgovor: **ima smisla, ali ne cijeli paket.** Skripte i dokumentacija su vrijedne
i mogu javno. Tuđi binarni instalateri ne smiju, i ne trebaju.

---

## Zašto ne cijeli paket

### 1. Licence
Paket nosi četiri tuđa proizvoda i **nijedan nema priloženu licencu**. Kod jednog je to
tvrdo ograničenje: **VB-Audio Virtual Cable** je donationware čiji uvjeti redistribuciju
instalatera ograničavaju. Sunshine i Moonlight su GPL-3.0 pa bi smjeli, ali nema razloga
hostati tuđe buildove.

### 2. Veličina
Paket je 35 MB (bio 98 dok su u njemu stajali Moonlight i stari instalater), od čega je gotovo sve tuđa binarna datoteka:

| Datoteka | Veličina |
|---|---|

| `Luxstream-Sunshine-patched.msi` | 32 MB |


Git nije mjesto za to. GitHub odbija datoteke preko 100 MB, a repozitorij bi rastao sa
svakom novom verzijom jer git čuva svaku.

### 3. Ono vrijedno je sitno
`INSTALL.ps1` + `scripts\` + dokumentacija su **ispod 300 KB**. To je ono što nitko drugi
nema i što je stajalo dana rada.

---

## Preporučena podjela

### a) Novi repozitorij — skripte i dokumentacija

```
INSTALL.cmd  INSTALL.ps1  scripts/  config/  templates/  host/
README.md  INSTALACIJA.md  RADNA-POSTAVA.md  GRAFIKA.md  TODO.md  FORK.md
```

Instalater ostaje isti; korisnik sam spusti drivere u `installers\` prema tablici izvora
u `installers\README.md`. `.gitignore` u paketu to već provodi.

### b) Zakrpani Sunshine — Release na forku `VjekoslavDugec/Luxstream`

Fork je GPL-3.0 i **već ima CI** koji gradi MSI (`build-windows-only.yml`). MSI ide kao
Release asset, ne u repozitorij. GPL je time uredno zadovoljen jer izvorni kod stoji uz
binarnu datoteku, u istom repozitoriju.

### c) Zakrpe prema upstreamu — najveća vrijednost

Dvije zakrpe su korisne svakome tko streama s GPU-P gosta:

| Commit | Što radi |
|---|---|
| `5247ed93` | ne propušta izlaze kroz Desktop Duplication probu kad je `capture = wgc` |
| `8f3c1676` | logira svaki korak `wgc_capture_t::init` i inicijalizira WinRT apartment |

`09e108f8` je dijagnostički i ne treba upstreamu.

Prva zakrpa je prava ispravka: Sunshine ima kompletan WGC backend, ali ga na GPU-P gostu
nikad ne dosegne jer ga Desktop Duplication proba odbije prije toga. Druga je pomogla
utvrditi da **SYSTEM ne može aktivirati Windows.Graphics.Capture** — nalaz koji upstream
vjerojatno zanima jer objašnjava zašto Sunshine kao servis na takvim gostima ne radi.

Ako prva zakrpa prođe upstream, **fork više neće trebati**.

---

## Što provjeriti prije objave

- [ ] licenca svake komponente u izvoru, osobito VB-Audio
- [ ] u repozitoriju nema `sunshine_state.json`, `credentials\*.pem`, ni `luxstream-identity.txt` — to su tajne i identitet ovog stroja
- [ ] u dokumentaciji nema internih IP adresa i imena strojeva (`192.168.6.*`, `lux1`, `GPU-test`)
- [ ] dodati vlastitu licencu (GPL-3.0 je prirodan izbor jer se nadograđuje na Sunshine)
- [ ] engleski `README.md` — nalaz o WGC-u i GPU-P-u je koristan šire, a dokumentacija je na hrvatskom

---

## Prije nego se objavi

Provjeri da u paketu nema tajni:

```powershell
Get-ChildItem -Recurse -Include *.pem,sunshine_state.json,luxstream-identity.txt
Select-String -Path *.md,scripts\*.ps1 -Pattern '192\.168\.|lux1' | Select-Object -First 20
```
