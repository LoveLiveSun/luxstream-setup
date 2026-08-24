' streamready-hidden.vbs
'
' Pokrece watchdog BEZ bljeska konzolnog prozora.
'
' ZASTO
'   Zadatak StreamReady ide svake minute. Task Scheduler pokretanjem
'   powershell.exe nakratko prikaze konzolni prozor - i to unatoc
'   `-WindowStyle Hidden`, jer se prozor stvori prije nego se stil primijeni.
'   Na svakoj minuti to je vidljiv bljesak preko cijele slike.
'
' KAKO
'   WScript.Shell.Run s drugim argumentom 0 prosljedjuje SW_HIDE u STARTUPINFO,
'   pa konzola nastane skrivena. wscript.exe je GUI program pa ni on ne bljesne.
'
'   Treci argument True znaci CEKAJ kraj. Bitno: bez cekanja bi Task Scheduler
'   smatrao zadatak gotovim odmah, pa bi uz MultipleInstances=IgnoreNew iduci
'   prolaz krenuo dok prethodni jos radi. Priming zna trajati 30-40 s.

Option Explicit

Dim ljuska, fso, skripta, naredba
Set fso = CreateObject("Scripting.FileSystemObject")
Set ljuska = CreateObject("WScript.Shell")

skripta = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "ensure-streaming-ready.ps1")

If Not fso.FileExists(skripta) Then
    ' bez dijaloga - ovo se vrti iz zadatka, prozor bi visio zauvijek
    WScript.Quit 1
End If

naredba = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & skripta & """ -Quiet"

' 0 = skriveni prozor, True = cekaj kraj
WScript.Quit ljuska.Run(naredba, 0, True)
