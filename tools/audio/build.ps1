param([switch]$ReuseRaw)
$ErrorActionPreference = 'Stop'
if (-not $ReuseRaw) { & (Join-Path $PSScriptRoot 'generate_tts.ps1'); if (-not $?) { throw 'TTS failed.' } }
& python (Join-Path $PSScriptRoot 'build_assets.py') build
if ($LASTEXITCODE -ne 0) { throw 'Asset build failed.' }
& python -B (Join-Path $PSScriptRoot 'test_audio_assets.py')
if ($LASTEXITCODE -ne 0) { throw 'Asset tests failed.' }
