# Start Ollama
$ollamaJob = Start-Job -ScriptBlock { & "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe" serve }
Start-Sleep -Seconds 8

# Verify its up
try {
    $r = Invoke-RestMethod "http://127.0.0.1:11434/api/tags" -TimeoutSec 5
    Write-Host "[setup] Ollama UP. Models: $($r.models.name -join ', ')"
} catch {
    Write-Host "[setup] FAILED to verify Ollama: $_"
    exit 1
}

# Run S2 then S3
Write-Host "[setup] Running Scenario 2..."
python scripts\test_cascade_v2.py 2

Write-Host "`n[setup] Running Scenario 3..."
python scripts\test_cascade_v2.py 3

Stop-Job $ollamaJob -PassThru | Remove-Job
Write-Host "[setup] Done."
