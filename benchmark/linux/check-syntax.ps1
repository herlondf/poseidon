$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    'D:\IA\Projetos\Delphi\Poseidon\benchmark\linux\run-bench.ps1',
    [ref]$tokens, [ref]$errors)
if ($errors.Count -eq 0) {
    Write-Host "No syntax errors."
} else {
    foreach ($e in $errors) {
        Write-Host ("L{0} C{1}: {2}" -f $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $e.Message)
    }
}
