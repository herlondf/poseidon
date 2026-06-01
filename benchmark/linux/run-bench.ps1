#Requires -Version 5.1
<#
.SYNOPSIS
    Compila BenchServer para Linux64 e executa o benchmark Poseidon vs Horse em container Docker na WSL.
    Gera relatorio HTML em benchmark/linux/results/.

.DESCRIPTION
    1. Compila BenchServer.dpr (variantes Poseidon e Horse/CrossSocket) via dcclinux64.exe
    2. Detecta ou usa a distro WSL indicada (padrao: Totvs, que ja tem Docker Engine)
    3. Constroi imagens Docker e sobe servicos (poseidon, horse, haproxy)
    4. Executa run-benchmark.sh dentro da WSL
    5. Para os servicos e abre o relatorio HTML

.PARAMETER SkipBuild
    Pula a compilacao (usa binarios existentes em assets/)

.PARAMETER WslDistro
    Nome da distro WSL com Docker Engine (padrao: Totvs)
#>
param(
    [switch]$SkipBuild,
    [string]$WslDistro = 'Totvs'
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ── Paths ─────────────────────────────────────────────────────────────────────
$ScriptDir  = $PSScriptRoot
$RepoRoot   = (Resolve-Path (Join-Path $ScriptDir '..\..') ).Path
$BenchSrc   = Join-Path $RepoRoot 'benchmark\src'
$SrcDir     = Join-Path $RepoRoot 'src'
$AssetsDir  = Join-Path $ScriptDir 'assets'
$DcuDir     = Join-Path $ScriptDir 'dcu'
$ResultsDir = Join-Path $ScriptDir 'results'

# dcclinux64.exe: preferir copia local (sem espacos no path — evita bug do ld-linux)
$DccLocal  = 'D:\IA\Projetos\WSL-Manager\tools\dcc\dcclinux64.exe'
$DccStudio = 'C:\Program Files (x86)\Embarcadero\Studio\22.0\bin\dcclinux64.exe'
$Dcc = if (Test-Path $DccLocal) { $DccLocal } else { $DccStudio }

# Delphi RTL Linux64 (via junction D:\Emb sem espacos)
$LibLinux   = 'D:\Emb\lib\linux64\release'
$SysrootDir = 'D:\IA\Projetos\WSL-Manager\tools\linux-sysroot'

# ── Helpers ───────────────────────────────────────────────────────────────────
function Write-Step { param($m) Write-Host "`n  >> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "  OK $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "  !  $m" -ForegroundColor Yellow }
function Write-Err  { param($m) Write-Host "  XX $m" -ForegroundColor Red }

function WslRun {
    param([string]$Distro, [string]$Cmd, [string]$User = 'root')
    $result = wsl.exe -d $Distro -u $User -- bash -lc $Cmd 2>&1
    return $result
}

function WslPath {
    # Converte D:\foo\bar -> /mnt/d/foo/bar
    param([string]$WinPath)
    $drive = $WinPath[0].ToString().ToLower()
    $rest  = $WinPath.Substring(2) -replace '\\', '/'
    return "/mnt/$drive$rest"
}

# ── Build Linux64 via dcclinux64.exe ─────────────────────────────────────────
function Build-Linux64 {
    param([string]$Defines, [string]$OutName)

    if (-not (Test-Path $Dcc)) {
        Write-Err "dcclinux64.exe nao encontrado em:`n    $Dcc"
        Write-Host "  Instale o componente 'Cross-compiler for Linux 64-bit' no RAD Studio." -ForegroundColor Yellow
        return $false
    }
    if (-not (Test-Path $LibLinux)) {
        Write-Err "RTL Linux64 nao encontrado em: $LibLinux"
        Write-Host "  Crie a junction: mklink /J D:\Emb `"C:\Program Files (x86)\Embarcadero\Studio\22.0`"" -ForegroundColor Yellow
        return $false
    }

    New-Item -ItemType Directory -Path $AssetsDir, $DcuDir -Force | Out-Null

    $dprFile = Join-Path $BenchSrc 'BenchServer.dpr'

    # Response file com todos os flags do compilador
    $rspLines = @(
        "-U`"$SrcDir`"",
        "-U`"$BenchSrc`"",
        "-U`"$LibLinux`"",
        "-I`"$SrcDir`"",
        "-I`"$BenchSrc`"",
        "-D$Defines",
        "-E`"$AssetsDir`"",
        "-N0`"$DcuDir`"",
        "-NSSystem;Xml;Data;Datasnap;Web;Soap",
        "--no-config",
        "-CC"
    )

    $rspFile = Join-Path $ScriptDir 'BenchServer.linux64.rsp'
    [System.IO.File]::WriteAllLines($rspFile, $rspLines, [System.Text.Encoding]::GetEncoding(1252))

    # Sysroot para cross-link (necessario quando compilando a partir do Windows)
    $sysArgs = ''
    if (Test-Path $SysrootDir) {
        $libpath = "$SysrootDir\lib\x86_64-linux-gnu;$SysrootDir\usr\lib\x86_64-linux-gnu;$SysrootDir\lib\gcc\x86_64-linux-gnu\13"
        $sysArgs = " --syslibroot:`"$SysrootDir`" --libpath:`"$libpath`""
    } else {
        Write-Warn "Sysroot nao encontrado em $SysrootDir — o linker pode falhar."
        Write-Host "  Execute para criar: wsl -d $WslDistro -- bash D:/IA/Projetos/WSL-Manager/scripts/setup-linux-sysroot.sh" -ForegroundColor DarkGray
    }

    # Script .cmd temporario: seta env vars sem espacos (evita bug do ld-linux.exe) e invoca dcclinux64
    $cmdTmp  = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.cmd'
    $outFile = $rspFile + '.out'
    $errFile = $rspFile + '.err'
    $cmdBody = "@echo off`r`n"
    $cmdBody += "SET BDS=D:\Emb`r`n"
    $cmdBody += "SET BDSLIB=D:\Emb\lib`r`n"
    $cmdBody += "SET BDSINCLUDE=D:\Emb\include`r`n"
    $cmdBody += "SET BDSCOMMONDIR=D:\EmbUser`r`n"
    $cmdBody += "SET BDSUSERDIR=D:\EmbUser`r`n"
    # --save-temps preserva BenchServer.lnk em $AssetsDir para o PatchLdBareC
    $cmdBody += "`"$Dcc`" `"@$rspFile`"$sysArgs --save-temps `"$dprFile`"`r`n"
    [System.IO.File]::WriteAllText($cmdTmp, $cmdBody, [System.Text.Encoding]::GetEncoding(1252))

    try {
        $sw   = [System.Diagnostics.Stopwatch]::StartNew()
        $proc = Start-Process -FilePath 'cmd.exe' `
            -ArgumentList "/d /c `"$cmdTmp`"" `
            -WorkingDirectory $BenchSrc `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile `
            -RedirectStandardError  $errFile
        $proc.WaitForExit(300000) | Out-Null
        $sw.Stop()

        $enc      = [System.Text.Encoding]::GetEncoding(1252)
        $raw      = ([System.IO.File]::ReadAllText($outFile, $enc)) + `
                    ([System.IO.File]::ReadAllText($errFile, $enc))
        $bareCErr = $raw -imatch 'cannot open c: No such file'
        $hasError = $raw -imatch 'Fatal: F[0-9]+|error: undefined reference|cannot find -l'
        $hasDone  = $raw -imatch 'lines compiled|\d+ lines,\s+\d+'
        $success  = ($proc.ExitCode -eq 0) -or ($hasDone -and -not $hasError)

        $raw -split "`n" |
            Where-Object { $_ -match 'Fatal:|Error: E[0-9]|Warning:|lines compiled|\d+ lines,' } |
            Select-Object -First 20 |
            ForEach-Object {
                $line  = $_.TrimEnd()
                $color = if ($line -imatch 'Fatal:|error:') { 'Red' } `
                         elseif ($line -imatch 'Warning:') { 'Yellow' } else { 'Green' }
                Write-Host "  $line" -ForegroundColor $color
            }

        # ── PatchLdBareC ──────────────────────────────────────────────────────
        # D:\Emb\bin\dcclinux64.cfg contem -u"c:\program files..." que injeta um
        # token bare 'c' no .lnk de resposta do ld-linux.exe.
        # --save-temps preserva o .lnk; limpamos o 'c' e relinkamos diretamente.
        # Nota: '-l' + 'c' (2 linhas) tb perde o 'c' na limpeza — readicionamos -lc.
        if (-not $success -and $bareCErr) {
            $lnkPath = Join-Path $AssetsDir 'BenchServer.lnk'
            if (Test-Path $lnkPath) {
                Write-Warn 'PatchLdBareC: limpando .lnk e relinkando via ld-linux.exe...'

                # Limpa tokens de 1 char (remove bare 'c' e quaisquer outros)
                $rawLnk   = [System.IO.File]::ReadAllLines($lnkPath)
                $cleanLnk = $rawLnk | Where-Object { $_.Trim().Length -gt 1 }
                $tmpLnk   = Join-Path $AssetsDir 'BenchServer.clean.lnk'
                [System.IO.File]::WriteAllLines($tmpLnk, $cleanLnk)

                $ldExe = 'D:\Emb\bin\ld-linux.exe'
                if (-not (Test-Path $ldExe)) {
                    $ldExe = 'C:\Program Files (x86)\Embarcadero\Studio\22.0\bin\ld-linux.exe'
                }

                # Entry point: BenchServer -> Benchserver -> _ZN11Benchserver14initializationEv
                $mangledName = 'B' + 'enchserver'
                $entry  = "_ZN$($mangledName.Length)${mangledName}14initializationEv"
                $outBin = Join-Path $AssetsDir 'BenchServer'
                $embLib = $LibLinux

                $ldArgs = [System.Collections.Generic.List[string]]::new()
                $ldArgs.AddRange([string[]]@(
                    '-o', $outBin,
                    '-e', $entry,
                    '--gc-sections', '-z', 'relro', '--build-id', '--eh-frame-hdr',
                    '-m', 'elf_x86_64',
                    '--dynamic-linker', '/lib64/ld-linux-x86-64.so.2',
                    '-s',
                    '--sysroot', $SysrootDir,
                    '-L', $embLib,
                    "-L$SysrootDir\lib\x86_64-linux-gnu",
                    "-L$SysrootDir\usr\lib\x86_64-linux-gnu",
                    "-L$SysrootDir\lib\gcc\x86_64-linux-gnu\13"
                ))
                $ldArgs.Add("@$tmpLnk")   # objects (bare 'c' already removed)
                $ldArgs.AddRange([string[]]@(   # libs (inclui -lc removido da limpeza)
                    '-lgcc_s', '-lrtlhelper_PIC', '-lc', '-ldl',
                    '-lpthread', '-lm', '-lrtlhelper', '-lpcre_PIC', '-lz',
                    '-rpath', '$ORIGIN'
                ))

                $ldErrFile = Join-Path $AssetsDir 'BenchServer.ld.err'
                $ldProc = Start-Process -FilePath $ldExe -ArgumentList $ldArgs `
                    -WorkingDirectory $AssetsDir -NoNewWindow -Wait -PassThru `
                    -RedirectStandardError $ldErrFile
                $ldErr = if (Test-Path $ldErrFile) {
                    [System.IO.File]::ReadAllText($ldErrFile)
                } else { '' }
                Remove-Item $tmpLnk, $lnkPath, $ldErrFile -Force -ErrorAction SilentlyContinue

                if ($ldProc.ExitCode -eq 0) {
                    Write-Ok 'PatchLdBareC relink OK.'
                    $success = $true
                } else {
                    Write-Err ("PatchLdBareC relink falhou (exit={0}):`n{1}" -f $ldProc.ExitCode, $ldErr)
                }
            } else {
                Write-Warn "PatchLdBareC: BenchServer.lnk nao encontrado em $AssetsDir"
            }
        }
        # ─────────────────────────────────────────────────────────────────────

        if ($success) {
            $outBin = Join-Path $AssetsDir 'BenchServer'
            if (Test-Path $outBin) {
                $destBin = Join-Path $AssetsDir $OutName
                if (Test-Path $destBin) { Remove-Item $destBin -Force }
                Rename-Item -Path $outBin -NewName $OutName
                $sz   = [Math]::Round((Get-Item $destBin).Length / 1024)
                $secs = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
                Write-Ok ('{0}  ({1} KB)  [{2}s]' -f $OutName, $sz, $secs)
            } else {
                Write-Err "Binario nao produzido em $AssetsDir"
                $success = $false
            }
        }

        if (-not $success) {
            Write-Err "Build falhou. Log completo: $outFile"
        } else {
            Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
        }
        return $success

    } finally {
        Remove-Item $cmdTmp, $rspFile -Force -ErrorAction SilentlyContinue
    }
}

# ── Cabecalho ─────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  +====================================================+' -ForegroundColor Magenta
Write-Host '  |   Poseidon Benchmark  --  Linux64 em Docker       |' -ForegroundColor Magenta
Write-Host '  +====================================================+' -ForegroundColor Magenta
Write-Host ''

New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
$LTS = Get-Date

# ── FASE 1: Compilacao ────────────────────────────────────────────────────────
if (-not $SkipBuild) {
    Write-Step 'Compilando BenchServer [Poseidon] para Linux64...'
    $ok = Build-Linux64 -Defines 'POSEIDON;NOGUI;RELEASE' -OutName 'bench-poseidon.linux64'
    if (-not $ok) { Write-Err 'Build Poseidon falhou.'; exit 1 }

    Write-Step 'Compilando BenchServer [Horse/CrossSocket] para Linux64...'
    $ok = Build-Linux64 -Defines 'HORSE_CROSSSOCKET;NOGUI;RELEASE' -OutName 'bench-horse-cs.linux64'
    if (-not $ok) {
        Write-Warn 'Build Horse/CrossSocket falhou (Horse nao instalado — comparacao sera limitada).'
    }
} else {
    Write-Warn 'Build pulado (-SkipBuild). Usando binarios existentes em assets/.'
    if (-not (Test-Path (Join-Path $AssetsDir 'bench-poseidon.linux64'))) {
        Write-Err "bench-poseidon.linux64 nao encontrado em assets/. Execute sem -SkipBuild."
        exit 1
    }
}

# ── FASE 2: Verificar WSL com Docker ─────────────────────────────────────────
Write-Step "Verificando Docker na WSL '$WslDistro'..."

$dockerVer = WslRun -Distro $WslDistro -Cmd 'docker --version 2>/dev/null'
if ($dockerVer -notmatch 'Docker version') {
    Write-Err "Docker Engine nao encontrado na distro '$WslDistro'."
    Write-Host "  Instale o Docker Engine na distro ou use -WslDistro <outra-distro>." -ForegroundColor Yellow
    exit 1
}
Write-Ok $dockerVer

# Garante que o daemon esta rodando
WslRun -Distro $WslDistro -Cmd 'service docker start 2>/dev/null; true' | Out-Null

# ── FASE 3: docker compose build ─────────────────────────────────────────────
$wslLinuxDir = WslPath $ScriptDir

Write-Step 'Construindo imagens Docker...'
$buildOut = WslRun -Distro $WslDistro -Cmd "cd '$wslLinuxDir' && docker compose build 2>&1"
$buildOut | Where-Object { $_ -match 'Step \d+|Successfully built|Successfully tagged|ERROR|error' } |
    ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
Write-Ok 'Imagens construidas.'

# ── FASE 4: docker compose up ─────────────────────────────────────────────────
Write-Step 'Subindo servicos (poseidon, horse, haproxy)...'
WslRun -Distro $WslDistro -Cmd "cd '$wslLinuxDir' && docker compose up -d poseidon horse haproxy 2>&1" | Out-Null

# Aguarda healthcheck dos servicos (max 30s)
Write-Host '  Aguardando healthcheck...' -ForegroundColor DarkGray
$deadline = (Get-Date).AddSeconds(60)
$allHealthy = $false
while ((Get-Date) -lt $deadline) {
    $posH  = (WslRun -Distro $WslDistro -Cmd "docker inspect --format='{{.State.Health.Status}}' poseidon  2>/dev/null").Trim()
    $horseH = (WslRun -Distro $WslDistro -Cmd "docker inspect --format='{{.State.Health.Status}}' horse 2>/dev/null").Trim()
    if ($posH -eq 'healthy' -and $horseH -eq 'healthy') { $allHealthy = $true; break }
    Start-Sleep -Seconds 2
}
if ($allHealthy) {
    Write-Ok 'Todos os servicos healthy.'
} else {
    Write-Warn 'Timeout de healthcheck (servicos podem nao estar prontos — o benchmark continuara).'
}

# ── FASE 5: Executar benchmark ────────────────────────────────────────────────
Write-Step 'Executando run-benchmark.sh...'
# Converte LF (scripts criados no Windows podem ter CRLF que causam bugs no bash)
WslRun -Distro $WslDistro -Cmd "sed -i 's/\r//' '$wslLinuxDir/run-benchmark.sh' '$wslLinuxDir/generate-report.sh' 2>/dev/null; true" | Out-Null
$benchOut = WslRun -Distro $WslDistro -Cmd "cd '$wslLinuxDir' && bash ./run-benchmark.sh 2>&1"
$benchOut | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

# ── FASE 6: docker compose down ──────────────────────────────────────────────
Write-Step 'Parando servicos Docker...'
WslRun -Distro $WslDistro -Cmd "cd '$wslLinuxDir' && docker compose down 2>&1" | Out-Null
Write-Ok 'Servicos parados.'

# ── FASE 7: Abrir relatorios ──────────────────────────────────────────────────
Write-Host ''
Write-Host '  =================== RESULTADOS ===================' -ForegroundColor Magenta

$newReports = @(Get-ChildItem $ResultsDir -Filter 'bench-report-*.html' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -gt $LTS } | Sort-Object Name)

foreach ($f in $newReports) {
    Write-Ok "Relatorio: $($f.Name)"
    Start-Process $f.FullName
}

if (-not $newReports) {
    Write-Warn 'Nenhum relatorio HTML encontrado.'
    Write-Host "  Verifique logs acima e arquivos em: $ResultsDir" -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '  Benchmark concluido!' -ForegroundColor Green
Write-Host ''
