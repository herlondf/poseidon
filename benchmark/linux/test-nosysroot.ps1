$Dcc      = 'D:\IA\Projetos\WSL-Manager\tools\dcc\dcclinux64.exe'
$SrcDir   = 'D:\IA\Projetos\Delphi\Poseidon\src'
$BenchSrc = 'D:\IA\Projetos\Delphi\Poseidon\benchmark\src'
$LibLinux = 'D:\Emb\lib\linux64\release'
$AssetsDir= 'D:\IA\Projetos\Delphi\Poseidon\benchmark\linux\assets'
$DcuDir   = 'D:\IA\Projetos\Delphi\Poseidon\benchmark\linux\dcu'

$rspLines = @(
    "-U`"$SrcDir`"",
    "-U`"$BenchSrc`"",
    "-U`"$LibLinux`"",
    "-I`"$SrcDir`"",
    "-I`"$BenchSrc`"",
    "-DPOSEIDON;NOGUI;RELEASE",
    "-E`"$AssetsDir`"",
    "-N0`"$DcuDir`"",
    "-NSSystem;Xml;Data;Datasnap;Web;Soap",
    "--no-config",
    "-CC"
)

$rspFile = Join-Path $PSScriptRoot 'test-nosysroot.rsp'
[System.IO.File]::WriteAllLines($rspFile, $rspLines, [System.Text.Encoding]::GetEncoding(1252))

$outFile = Join-Path $PSScriptRoot 'test-nosysroot.out'
$errFile = Join-Path $PSScriptRoot 'test-nosysroot.err'
$cmdBody  = "@echo off`r`nSET BDS=D:\Emb`r`nSET BDSLIB=D:\Emb\lib`r`n"
$cmdBody += "`"$Dcc`" `"@$rspFile`" --save-temps `"$BenchSrc\BenchServer.dpr`"`r`n"
$cmdTmp   = Join-Path $env:TEMP 'test_nosysroot_build.cmd'
[System.IO.File]::WriteAllText($cmdTmp, $cmdBody, [System.Text.Encoding]::GetEncoding(1252))

$proc = Start-Process 'cmd.exe' -ArgumentList "/d /c `"$cmdTmp`"" `
    -WorkingDirectory $BenchSrc -NoNewWindow -PassThru `
    -RedirectStandardOutput $outFile -RedirectStandardError $errFile -Wait

$enc = [System.Text.Encoding]::GetEncoding(1252)
$raw = ([System.IO.File]::ReadAllText($outFile, $enc)) + ([System.IO.File]::ReadAllText($errFile, $enc))

Write-Host "Exit: $($proc.ExitCode)"
$raw -split "`n" | Where-Object { $_ -match 'cannot open|Linker error|lines compiled|undefined|Warning:|Error:' } |
    Select-Object -First 30 | ForEach-Object { Write-Host $_.TrimEnd() }

Remove-Item $cmdTmp, $rspFile -Force -ErrorAction SilentlyContinue
