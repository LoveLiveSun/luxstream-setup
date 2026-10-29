' luxstream-bridge-hidden.vbs
'
' Pokrece most (luxstream-bridge.ps1) BEZ bljeska konzolnog prozora.
'
' ZASTO
'   Task Scheduler pokretanjem powershell.exe nakratko prikaze konzolni
'   prozor - i to unatoc `-WindowStyle Hidden`, jer se prozor stvori prije
'   nego se stil primijeni. Isti razlog kao kod streamready-hidden.vbs i
'   start-sunshine-hidden.vbs.
'
' KAKO
'   WScript.Shell.Run s drugim argumentom 0 prosljedjuje SW_HIDE u
'   STARTUPINFO, pa konzola nastane skrivena. wscript.exe je GUI program pa
'   ni on ne bljesne.
'
'   Treci argument je False - NE cekaj kraj. Most je trajan proces (vrti se
'   dok je veza ziva), pa bi cekanje drzalo zadatak "u tijeku" zauvijek i
'   blokiralo MultipleInstances=IgnoreNew. Za razliku od watchdoga, koji
'   zavrsi u 30-40 s i zato smije cekati.
'
' ZASTO OVAJ OMOTAC NE CITA KONFIGURACIJU
'   Nacini rada, port i zajednicka tajna stoje u
'   C:\ProgramData\Luxstream\bridge.json, koji zapisuje
'   `luxstream-bridge.ps1 -Install`. Ali most ih ionako cita sam, kad mu se
'   ne zadaju na naredbenom retku. Parsiranje JSON-a u VBScriptu bilo bi
'   pedesetak redaka regexa bez ikakve koristi - i to redaka koje treba
'   odrzavati u koraku s onim sto PowerShell zapisuje. Zato se ovdje ne
'   cita nista: predaje se samo -Quiet, a most se snadje sam.
'
'   Ako konfiguracije nema, most to zapise u
'   %USERPROFILE%\Luxstream\luxstream-bridge.log i izadje. Provjeri stanje s:
'       powershell -ExecutionPolicy Bypass -File luxstream-bridge.ps1 -Status
'
' UPOTREBA
'   wscript.exe "C:\...\scripts\luxstream-bridge-hidden.vbs"

Option Explicit

Dim fso, ljuska, skripta, naredba
Set fso = CreateObject("Scripting.FileSystemObject")
Set ljuska = CreateObject("WScript.Shell")

skripta = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "luxstream-bridge.ps1")

' Bez skripte nema sto pokrenuti. Tise bez dijaloga - ovo se vrti iz
' zadatka, a prozor s porukom bi visio zauvijek.
If Not fso.FileExists(skripta) Then WScript.Quit 1

naredba = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & skripta & """ -Quiet"

' 0 = skriveni prozor, False = ne cekaj kraj (most je trajan proces)
ljuska.Run naredba, 0, False

WScript.Quit 0
