$ldExe   = 'D:\Emb\bin\ld-linux.exe'
$lnkPath = 'D:\IA\Projetos\Delphi\Poseidon\benchmark\linux\assets\BenchServer.lnk'
$AssetsDir = 'D:\IA\Projetos\Delphi\Poseidon\benchmark\linux\assets'
$SysrootDir = 'D:\IA\Projetos\WSL-Manager\tools\linux-sysroot'
$LibLinux   = 'D:\Emb\lib\linux64\release'
$outBin     = "$AssetsDir\BenchServer"

Write-Host "ld exists: $(Test-Path $ldExe)"
Write-Host "lnk exists: $(Test-Path $lnkPath)"
Write-Host "lnk lines: $((Get-Content $lnkPath -Encoding Default).Count)"
Write-Host "lnk first: $((Get-Content $lnkPath -Encoding Default)[0])"

# Test 1: just the output flag
$errFile = "$AssetsDir\ld.err"
$args1 = [System.Collections.Generic.List[string]]::new()
$args1.AddRange([string[]]@('-o', $outBin, '-m', 'elf_x86_64', "-L$LibLinux", "@$lnkPath"))
$p1 = Start-Process -FilePath $ldExe -ArgumentList $args1 -WorkingDirectory $AssetsDir `
    -NoNewWindow -Wait -PassThru -RedirectStandardError $errFile
$e1 = if (Test-Path $errFile) { Get-Content $errFile -Raw -Encoding Default } else { '' }
Write-Host ""
Write-Host "Test1 (no sysroot) exit=$($p1.ExitCode):"
$e1 -split "`n" | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" }

Remove-Item $errFile -Force -ErrorAction SilentlyContinue
if (Test-Path $outBin) { Remove-Item $outBin -Force }
