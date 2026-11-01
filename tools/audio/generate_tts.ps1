param(
    [string]$Voice = 'Microsoft Huihui Desktop',
    [ValidateRange(-10, 10)][int]$Rate = 0
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech
$s19Root = $PSScriptRoot
$s19Manifest = Get-Content -LiteralPath (Join-Path $s19Root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$s19Raw = Join-Path $s19Root 'raw_wav'
[void](New-Item -ItemType Directory -Path $s19Raw -Force)
$s19Synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
function Get-S19Sha256([string]$Path) {
    $s19Hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $s19Digest = $s19Hasher.ComputeHash([IO.File]::ReadAllBytes($Path))
        return [BitConverter]::ToString($s19Digest).Replace('-', '').ToLowerInvariant()
    } finally { $s19Hasher.Dispose() }
}
try {
    $s19Voices = @($s19Synth.GetInstalledVoices() | ForEach-Object {
        [ordered]@{ name = $_.VoiceInfo.Name; culture = $_.VoiceInfo.Culture.Name; enabled = $_.Enabled }
    })
    $s19Synth.SelectVoice($Voice)
    if ($s19Synth.Voice.Culture.Name -ne 'zh-CN') { throw 'A zh-CN offline voice is required.' }
    $s19Synth.Rate = $Rate
    $s19Synth.Volume = [int]$s19Manifest.tts.volume
    $s19Format = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(
        16000,
        [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen,
        [System.Speech.AudioFormat.AudioChannel]::Mono
    )
    $s19Records = @()
    foreach ($s19Entry in $s19Manifest.entries) {
        if ($s19Entry.kind -ne 'speech') { continue }
        if ($s19Entry.key -notmatch '^[a-z0-9_]+$') { throw 'Invalid asset key.' }
        $s19Name = '{0:D2}_{1}.wav' -f [int]$s19Entry.id, $s19Entry.key
        $s19Path = Join-Path $s19Raw $s19Name
        $s19Synth.SetOutputToWaveFile($s19Path, $s19Format)
        try { $s19Synth.Speak([string]$s19Entry.text) }
        finally { $s19Synth.SetOutputToNull() }
        $s19Records += [ordered]@{id = [int]$s19Entry.id; file = $s19Name; text = [string]$s19Entry.text; sha256 = (Get-S19Sha256 $s19Path)}
        Write-Host ('TTS {0}' -f $s19Name)
    }
    $s19Meta = [ordered]@{
        engine = 'System.Speech'; voice = $s19Synth.Voice.Name; culture = $s19Synth.Voice.Culture.Name
        rate = $Rate; volume = $s19Synth.Volume; sample_rate = 16000; pcm_bits = 16; channels = 1
        assembly = [System.Speech.Synthesis.SpeechSynthesizer].Assembly.FullName
        powershell = $PSVersionTable.PSVersion.ToString(); os = [Environment]::OSVersion.VersionString
        installed_voices = $s19Voices; records = $s19Records
    }
    $s19Json = $s19Meta | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText((Join-Path $s19Raw 'tts_provenance.json'), $s19Json, (New-Object Text.UTF8Encoding($false)))
} finally { $s19Synth.Dispose() }
