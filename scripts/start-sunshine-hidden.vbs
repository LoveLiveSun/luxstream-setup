' start-sunshine-hidden.vbs
'
' Pokrece Sunshine BEZ vidljivog konzolnog prozora.
'
' ZASTO
'   Sunshine.exe je gradjen kao KONZOLNA aplikacija (PE Subsystem = 3), pa mu
'   Windows sam stvara konzolni prozor. To nije stvar nacina pokretanja i ne da
'   se iskljuciti prekidacem - `Sunshine.exe --help` nudi samo --creds, --version
'   i zastavice -0 -1 -2 -p. Nema headless ni no-console opcije.
'
'   Kad je Sunshine isao kao servis, prozora nije bilo jer servisi nemaju radnu
'   povrsinu. Otkad mora ici kao korisnik (SYSTEM ne moze aktivirati WGC),
'   prozor je postao vidljiv.
'
' KAKO
'   WScript.Shell.Run s drugim argumentom 0 prosljedjuje SW_HIDE u STARTUPINFO,
'   pa konzola nastane skrivena. Nema ni bljeska, jer je wscript.exe GUI program.
'   Treci argument False znaci "ne cekaj kraj".
'
' UPOTREBA
'   wscript.exe "C:\...\scripts\start-sunshine-hidden.vbs"

Option Explicit

Dim ljuska, putanja, fso
Set fso = CreateObject("Scripting.FileSystemObject")
Set ljuska = CreateObject("WScript.Shell")

putanja = "C:\Program Files\Sunshine\Sunshine.exe"

If Not fso.FileExists(putanja) Then
    ' bez poruke - ovo se pokrece iz zakazanog zadatka, dijalog bi visio
    WScript.Quit 1
End If

ljuska.CurrentDirectory = fso.GetParentFolderName(putanja)
' 0 = skriveni prozor, False = ne cekaj
ljuska.Run """" & putanja & """", 0, False
WScript.Quit 0
