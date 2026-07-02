$ldDir = 'D:\Emb\bin'
# Check for ldscripts dir and linker config
if (Test-Path "$ldDir\ldscripts") {
    Write-Host "ldscripts/ EXISTS"
    Get-ChildItem "$ldDir\ldscripts" | Select-Object -First 10 | ForEach-Object { Write-Host "  $($_.Name)" }
} else {
    Write-Host "ldscripts/ NOT FOUND at $ldDir"
}

# Try running ld-linux.exe with --version
$p = Start-Process -FilePath "$ldDir\ld-linux.exe" -ArgumentList '--version' -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput 'D:\Temp\ld-ver.txt' -RedirectStandardError 'D:\Temp\ld-ver.err'
if (Test-Path 'D:\Temp\ld-ver.txt') { Write-Host (Get-Content 'D:\Temp\ld-ver.txt' -Raw) }
if (Test-Path 'D:\Temp\ld-ver.err') { Write-Host (Get-Content 'D:\Temp\ld-ver.err' -Raw) }

# Run with -verbose to see what the linker is doing
$p2 = Start-Process -FilePath "$ldDir\ld-linux.exe" `
    -ArgumentList @('-verbose', '-m', 'elf_x86_64', '--version') `
    -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput 'D:\Temp\ld-verbose.txt' -RedirectStandardError 'D:\Temp\ld-verbose.err'
$vo = if (Test-Path 'D:\Temp\ld-verbose.txt') { Get-Content 'D:\Temp\ld-verbose.txt' -Raw -Encoding Default } else { '' }
Write-Host "Verbose first 30 lines:"
$vo -split "`n" | Select-Object -First 30 | ForEach-Object { Write-Host "  $_" }
