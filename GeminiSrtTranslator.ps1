param(
    [switch]$WorkerMode,
    [switch]$MockWorkerMode,
    [switch]$RunSelfTests,
    [string]$InputPath,
    [string]$Direction,
    [string]$LogFile,
    [string]$ProgressFile,
    [string]$ResultFile,
    [string]$DoneFile
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security

$ErrorActionPreference = 'Stop'

$AppName = 'Gemini SRT Translator'
$ConfigDir = Join-Path $env:APPDATA 'GeminiSrtTranslator'
$KeyFile = Join-Path $ConfigDir 'key.bin'
$ModelName = 'gemini-3.5-flash'
$ChunkSize = 20

$RLM = [char]0x200F
$LRI = [char]0x2066
$RLI = [char]0x2067
$PDI = [char]0x2069

function Ensure-ConfigDir {
    if (-not (Test-Path -LiteralPath $ConfigDir)) {
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    }
}

function Save-ApiKey {
    param([string]$ApiKey)

    Ensure-ConfigDir
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($ApiKey)
    $protected = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    [System.IO.File]::WriteAllBytes($KeyFile, $protected)
}

function Load-ApiKey {
    if (-not (Test-Path -LiteralPath $KeyFile)) {
        return $null
    }

    try {
        $protected = [System.IO.File]::ReadAllBytes($KeyFile)
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $protected,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch {
        return $null
    }
}

function Show-ApiKeyDialog {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Gemini API Key'
    $form.StartPosition = 'CenterParent'
    $form.Size = New-Object System.Drawing.Size(620, 430)
    $form.MinimumSize = New-Object System.Drawing.Size(620, 430)

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(16, 16)
    $label.Size = New-Object System.Drawing.Size(570, 215)
    $label.Text = @"
This app uses the Gemini API to translate SRT subtitles.

How to get an API key:
1. Open Google AI Studio:
   https://aistudio.google.com/app/apikey
2. Sign in with your Google account.
3. Click "Create API key".
4. If prompted, create or choose a Google Cloud project.
5. Copy the API key.
6. Paste it below and click Save.

The key is saved encrypted for your Windows user in:
%APPDATA%\GeminiSrtTranslator\key.bin

It will be loaded automatically on future runs.
"@
    $form.Controls.Add($label)

    $link = New-Object System.Windows.Forms.LinkLabel
    $link.Location = New-Object System.Drawing.Point(16, 240)
    $link.Size = New-Object System.Drawing.Size(570, 24)
    $link.Text = 'Open Google AI Studio API Keys page'
    $link.Add_LinkClicked({
        Start-Process 'https://aistudio.google.com/app/apikey'
    })
    $form.Controls.Add($link)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point(16, 275)
    $textBox.Size = New-Object System.Drawing.Size(570, 24)
    $textBox.UseSystemPasswordChar = $true
    $form.Controls.Add($textBox)

    $showCheck = New-Object System.Windows.Forms.CheckBox
    $showCheck.Location = New-Object System.Drawing.Point(16, 306)
    $showCheck.Size = New-Object System.Drawing.Size(160, 24)
    $showCheck.Text = 'Show key'
    $showCheck.Add_CheckedChanged({
        $textBox.UseSystemPasswordChar = -not $showCheck.Checked
    })
    $form.Controls.Add($showCheck)

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Location = New-Object System.Drawing.Point(390, 340)
    $saveButton.Size = New-Object System.Drawing.Size(90, 32)
    $saveButton.Text = 'Save'
    $saveButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($saveButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Location = New-Object System.Drawing.Point(495, 340)
    $cancelButton.Size = New-Object System.Drawing.Size(90, 32)
    $cancelButton.Text = 'Cancel'
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $saveButton
    $form.CancelButton = $cancelButton

    if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    $key = $textBox.Text.Trim()
    if (-not $key) {
        [System.Windows.Forms.MessageBox]::Show(
            'No API key was entered.',
            $AppName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return $null
    }

    Save-ApiKey $key
    return $key
}

function Get-ApiKey {
    $key = Load-ApiKey
    if ($key) {
        return $key
    }
    return Show-ApiKeyDialog
}

function Test-Hebrew {
    param([string]$Text)
    return $Text -match '[\u0590-\u05FF]'
}

function Normalize-AssAlignment {
    param([string]$Line)
    $line = [regex]::Replace($Line, '\{[\\/]אנ(\d+)\}', '{\an$1}')
    return [regex]::Replace($line, '\{[\\/]an(\d+)\}', '{\an$1}')
}

function Add-AfterTrailingPunctuation {
    param([string]$Text)
    return [regex]::Replace($Text, '([.!?,:;])(\s*)$', "`$1$RLM`$2")
}

function Prefix-AfterLeadingSpace {
    param([string]$Text, [string]$Prefix)
    $match = [regex]::Match($Text, '^\s*')
    return $Text.Substring(0, $match.Length) + $Prefix + $Text.Substring($match.Length)
}

function Suffix-BeforeTrailingSpace {
    param([string]$Text, [string]$Suffix)
    $trimmedLength = $Text.TrimEnd().Length
    if ($trimmedLength -gt 0 -and $Text.Substring(0, $trimmedLength).EndsWith($Suffix)) {
        return $Text
    }
    return $Text.Substring(0, $trimmedLength) + $Suffix + $Text.Substring($trimmedLength)
}

function Fix-SubtitleLineRtl {
    param([string]$Line)

    $line = [regex]::Replace($Line, '[\u200E\u200F\u202A-\u202E\u2066-\u2069]', '')
    $line = Normalize-AssAlignment $line

    $tagPattern = '(\{\\[^}]*\}|</?[^>]+>)'
    $parts = [regex]::Split($line, $tagPattern)
    $textIndexes = New-Object System.Collections.Generic.List[int]

    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($parts[$i] -and -not [regex]::IsMatch($parts[$i], "^$tagPattern$")) {
            $textIndexes.Add($i)
        }
    }

    if ($textIndexes.Count -eq 0) {
        return $line
    }

    $joinedText = (($textIndexes | ForEach-Object { $parts[$_] }) -join '')
    if (-not (Test-Hebrew $joinedText)) {
        return $line
    }

    for ($i = 0; $i -lt $textIndexes.Count; $i++) {
        $idx = $textIndexes[$i]
        $parts[$idx] = [regex]::Replace(
            $parts[$idx],
            "[A-Za-z0-9]+(?:[._:/@#+&%'-][A-Za-z0-9]+)*",
            { param($m) "$LRI$($m.Value)$PDI" }
        )
    }

    $first = $textIndexes[0]
    $last = $textIndexes[$textIndexes.Count - 1]
    $parts[$first] = Prefix-AfterLeadingSpace $parts[$first] $RLI
    $parts[$last] = Add-AfterTrailingPunctuation $parts[$last]
    $parts[$last] = Suffix-BeforeTrailingSpace $parts[$last] $PDI

    return ($parts -join '')
}

function Clean-AndFixRtl {
    param([string]$SrtText)

    $lines = $SrtText -split "`n", 0, 'SimpleMatch'
    $fixed = foreach ($line in $lines) {
        $stripped = $line.Trim().TrimStart([char]0xFEFF)
        if (-not $stripped -or $stripped -match '^\d+$' -or $stripped.Contains('-->')) {
            $line
        } else {
            Fix-SubtitleLineRtl $line
        }
    }
    return ($fixed -join "`n")
}

function Convert-SrtToTranslationItems {
    param([string]$Content)

    $content = $Content -replace "`r`n", "`n"
    $content = $content -replace "`r", "`n"
    $blocks = [regex]::Split($content.Trim(), "\n\s*\n")
    $items = New-Object System.Collections.Generic.List[object]

    foreach ($block in $blocks) {
        $lines = $block -split "`n"
        if ($lines.Count -ge 3) {
            $text = (($lines[2..($lines.Count - 1)] -join "`n") -replace "`n", " `n ")
            $items.Add([pscustomobject]@{
                Index = $lines[0]
                Timestamp = $lines[1]
                Text = $text
            })
        }
    }

    Write-Output -NoEnumerate $items
}

function Get-SubtitleLanguageProfile {
    param([string]$Content)

    $items = Convert-SrtToTranslationItems $Content
    $sample = (($items | Select-Object -First 80 | ForEach-Object { $_.Text }) -join ' ')

    $sample = [regex]::Replace($sample, '<[^>]+>|\{\\[^}]*\}', ' ')
    $sample = [regex]::Replace($sample, '\s+', ' ')

    $hebrewCount = ([regex]::Matches($sample, '[\u0590-\u05FF]')).Count
    $latinCount = ([regex]::Matches($sample, '[A-Za-z]')).Count

    $likelyLanguage = 'Unknown'
    if ($hebrewCount -ge 20 -and $hebrewCount -ge ($latinCount * 2)) {
        $likelyLanguage = 'Hebrew'
    } elseif ($latinCount -ge 40 -and $latinCount -ge ($hebrewCount * 2)) {
        $likelyLanguage = 'English'
    }

    return [pscustomobject]@{
        LikelyLanguage = $likelyLanguage
        HebrewCount = $hebrewCount
        LatinCount = $latinCount
        BlockCount = $items.Count
    }
}

function Test-TranslationDirectionLooksValid {
    param([string]$InputPath, [string]$Direction)

    $content = [System.IO.File]::ReadAllText($InputPath, [System.Text.Encoding]::UTF8)
    $profile = Get-SubtitleLanguageProfile $content

    if ($Direction -eq 'Hebrew to English' -and $profile.LikelyLanguage -eq 'English') {
        return [pscustomobject]@{
            IsValid = $false
            Message = "This subtitle already looks English.`r`n`r`nSelected direction: Hebrew to English.`r`nDetected: English-like text.`r`n`r`nSwitch to English to Hebrew, or choose a Hebrew subtitle."
            Profile = $profile
        }
    }

    if ($Direction -eq 'English to Hebrew' -and $profile.LikelyLanguage -eq 'Hebrew') {
        return [pscustomobject]@{
            IsValid = $false
            Message = "This subtitle already looks Hebrew.`r`n`r`nSelected direction: English to Hebrew.`r`nDetected: Hebrew-like text.`r`n`r`nSwitch to Hebrew to English, or choose an English subtitle."
            Profile = $profile
        }
    }

    return [pscustomobject]@{
        IsValid = $true
        Message = ''
        Profile = $profile
    }
}

function Invoke-GeminiTranslation {
    param(
        [string[]]$Texts,
        [string]$ApiKey,
        [string]$Direction
    )

    if ($Direction -eq 'Hebrew to English') {
        $instruction = 'Translate each subtitle string from Hebrew to natural English. Preserve SRT/HTML/ASS tags, line-break placeholders, names, punctuation, and meaning. Return only a JSON array of strings in the same order.'
    } else {
        $instruction = 'Translate each subtitle string from English to natural Hebrew. Preserve SRT/HTML/ASS tags, line-break placeholders, names, punctuation, and meaning. Return only a JSON array of strings in the same order.'
    }

    $prompt = $instruction + "`nInput:`n" + ($Texts | ConvertTo-Json -Compress)
    $payload = @{
        contents = @(
            @{
                parts = @(
                    @{ text = $prompt }
                )
            }
        )
        generationConfig = @{
            responseMimeType = 'application/json'
        }
    } | ConvertTo-Json -Depth 10

    $uri = "https://generativelanguage.googleapis.com/v1beta/models/$ModelName`:generateContent?key=$ApiKey"
    $response = Invoke-RestMethod -Method Post -Uri $uri -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($payload))
    return Convert-GeminiResponseToStringArray -Response $response
}

function Convert-GeminiResponseToStringArray {
    param([object]$Response)

    if (-not $Response) {
        throw 'Gemini returned an empty response.'
    }
    if (-not $Response.candidates -or $Response.candidates.Count -lt 1) {
        $reason = $Response.promptFeedback.blockReason
        if ($reason) {
            throw "Gemini returned no candidates. Prompt was blocked: $reason."
        }
        throw 'Gemini returned no candidates.'
    }

    $candidate = $Response.candidates[0]
    if ($candidate.finishReason -and $candidate.finishReason -ne 'STOP') {
        throw "Gemini response finished with reason: $($candidate.finishReason)."
    }
    if (-not $candidate.content -or -not $candidate.content.parts -or $candidate.content.parts.Count -lt 1) {
        throw 'Gemini returned a candidate without text content.'
    }

    $jsonText = [string]$candidate.content.parts[0].text
    if (-not $jsonText.Trim()) {
        throw 'Gemini returned empty text content.'
    }

    try {
        $parsed = @($jsonText | ConvertFrom-Json)
    } catch {
        $preview = $jsonText
        if ($preview.Length -gt 300) {
            $preview = $preview.Substring(0, 300) + '...'
        }
        throw "Gemini returned invalid JSON: $preview"
    }

    if ($parsed.Count -lt 1) {
        throw 'Gemini returned an empty translation array.'
    }

    Write-Output -NoEnumerate $parsed
}

function Get-OutputPath {
    param([string]$InputPath, [string]$Direction)

    $dir = Split-Path -Parent $InputPath
    $name = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)

    if ($Direction -eq 'Hebrew to English') {
        $base = $name -replace '(?i)\.(heb|he)$', ''
        return Join-Path $dir "$base.eng.srt"
    }

    $base = $name -replace '(?i)\.(eng|en)$', ''
    return Join-Path $dir "$base.heb.srt"
}

function Read-WorkerResultFile {
    param([string]$ResultFilePath)

    if ([string]::IsNullOrWhiteSpace($ResultFilePath)) {
        throw 'Worker result file path is empty.'
    }
    if (-not (Test-Path -LiteralPath $ResultFilePath)) {
        throw "Worker result file is missing: $ResultFilePath"
    }

    $output = ([System.IO.File]::ReadAllText($ResultFilePath, [System.Text.Encoding]::UTF8)).Trim()
    if (-not $output) {
        throw "Worker result file is empty: $ResultFilePath"
    }

    return $output
}

function Format-ErrorDetails {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    $lines = New-Object System.Collections.Generic.List[string]
    $message = $ErrorRecord.Exception.Message
    if (-not $message) {
        $message = 'Unknown error.'
    }

    $lines.Add("Error: $message")
    $lines.Add("Type: $($ErrorRecord.Exception.GetType().FullName)")

    if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.PositionMessage) {
        $lines.Add($ErrorRecord.InvocationInfo.PositionMessage.Trim())
    }
    if ($ErrorRecord.ScriptStackTrace) {
        $lines.Add('Stack:')
        $lines.Add($ErrorRecord.ScriptStackTrace.Trim())
    }

    return ($lines -join "`n")
}

function Translate-SrtFile {
    param(
        [string]$InputPath,
        [string]$Direction,
        [string]$ApiKey,
        [scriptblock]$Log,
        [scriptblock]$SetProgress,
        [scriptblock]$ShouldCancel
    )

    $content = [System.IO.File]::ReadAllText($InputPath, [System.Text.Encoding]::UTF8)
    $items = Convert-SrtToTranslationItems $content
    if ($items.Count -eq 0) {
        throw 'No valid SRT subtitle blocks were found.'
    }

    & $Log "Parsed $($items.Count) subtitle blocks."
    $translatedBlocks = New-Object System.Collections.Generic.List[string]
    $current = 0

    while ($current -lt $items.Count) {
        if (& $ShouldCancel) {
            throw 'Canceled by user.'
        }

        $end = [Math]::Min($current + $ChunkSize - 1, $items.Count - 1)
        $chunk = @($items[$current..$end])
        & $SetProgress ([int](($current / [Math]::Max(1, $items.Count)) * 100))
        & $Log "Translating blocks $($current + 1)-$($end + 1)..."

        $translatedTexts = $null
        $lastError = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                $translatedTexts = Invoke-GeminiTranslation -Texts @($chunk | ForEach-Object { $_.Text }) -ApiKey $ApiKey -Direction $Direction
                break
            } catch {
                $lastError = $_
                & $Log "Attempt $attempt failed. Retrying..."
                Start-Sleep -Seconds 2
            }
        }

        if (-not $translatedTexts) {
            throw $lastError
        }

        if (& $ShouldCancel) {
            throw 'Canceled by user.'
        }

        if ($translatedTexts.Count -ne $chunk.Count) {
            throw "Gemini returned $($translatedTexts.Count) strings for $($chunk.Count) input subtitles."
        }

        for ($i = 0; $i -lt $chunk.Count; $i++) {
            $text = [string]$translatedTexts[$i]
            $text = ($text -replace " `n ", "`n").Trim()
            $translatedBlocks.Add("$($chunk[$i].Index)`n$($chunk[$i].Timestamp)`n$text")
        }

        $current += $ChunkSize
        & $SetProgress ([int](($current / [Math]::Max(1, $items.Count)) * 100))
    }

    $result = ($translatedBlocks -join "`n`n")
    if ($Direction -eq 'English to Hebrew') {
        $result = Clean-AndFixRtl $result
    }

    if (& $ShouldCancel) {
        throw 'Canceled by user.'
    }

    $outputPath = Get-OutputPath -InputPath $InputPath -Direction $Direction
    [System.IO.File]::WriteAllText($outputPath, $result, (New-Object System.Text.UTF8Encoding($true)))
    & $SetProgress 100
    return $outputPath
}

function Invoke-WorkerMode {
    try {
        $apiKey = Get-ApiKey
        if (-not $apiKey) {
            throw 'No Gemini API key is available.'
        }

        $writeLog = {
            param([string]$Message)
            Add-Content -LiteralPath $LogFile -Value "[$(Get-Date -Format HH:mm:ss)] $Message" -Encoding UTF8
        }

        $writeProgress = {
            param([int]$Value)
            [System.IO.File]::WriteAllText($ProgressFile, [string][Math]::Max(0, [Math]::Min(100, $Value)))
        }

        $output = Translate-SrtFile `
            -InputPath $InputPath `
            -Direction $Direction `
            -ApiKey $apiKey `
            -Log $writeLog `
            -SetProgress $writeProgress `
            -ShouldCancel { $false }

        [System.IO.File]::WriteAllText($ResultFile, $output, [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($DoneFile, 'OK', [System.Text.Encoding]::UTF8)
        exit 0
    } catch {
        $details = Format-ErrorDetails $_
        Add-Content -LiteralPath $LogFile -Value "[$(Get-Date -Format HH:mm:ss)] $details" -Encoding UTF8
        [System.IO.File]::WriteAllText($DoneFile, "ERROR`n$details", [System.Text.Encoding]::UTF8)
        exit 1
    }
}

function Invoke-MockWorkerMode {
    try {
        Add-Content -LiteralPath $LogFile -Value "[$(Get-Date -Format HH:mm:ss)] Parsed 40 subtitle blocks." -Encoding UTF8
        [System.IO.File]::WriteAllText($ProgressFile, '0', [System.Text.Encoding]::UTF8)
        Start-Sleep -Milliseconds 300
        Add-Content -LiteralPath $LogFile -Value "[$(Get-Date -Format HH:mm:ss)] Translating blocks 1-20..." -Encoding UTF8
        [System.IO.File]::WriteAllText($ProgressFile, '50', [System.Text.Encoding]::UTF8)
        Start-Sleep -Milliseconds 300
        Add-Content -LiteralPath $LogFile -Value "[$(Get-Date -Format HH:mm:ss)] Translating blocks 21-40..." -Encoding UTF8
        [System.IO.File]::WriteAllText($ProgressFile, '100', [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($ResultFile, 'C:\Temp\translated.eng.srt', [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($DoneFile, 'OK', [System.Text.Encoding]::UTF8)
        exit 0
    } catch {
        $details = Format-ErrorDetails $_
        Add-Content -LiteralPath $LogFile -Value "[$(Get-Date -Format HH:mm:ss)] $details" -Encoding UTF8
        [System.IO.File]::WriteAllText($DoneFile, "ERROR`n$details", [System.Text.Encoding]::UTF8)
        exit 1
    }
}

function Assert-Equal {
    param([object]$Actual, [object]$Expected, [string]$Name)
    if ($Actual -ne $Expected) {
        throw "$Name failed. Expected '$Expected', got '$Actual'."
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) {
        throw "$Name failed."
    }
}

function Assert-ThrowsLike {
    param([scriptblock]$ScriptBlock, [string]$Pattern, [string]$Name)
    try {
        & $ScriptBlock
    } catch {
        if ($_.Exception.Message -match $Pattern) {
            return
        }
        throw "$Name failed. Unexpected error: $($_.Exception.Message)"
    }
    throw "$Name failed. Expected an error matching '$Pattern'."
}

function Invoke-SelfTests {
    $tmp = Join-Path $env:TEMP ('gst-selftest-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        Assert-Equal (Get-OutputPath (Join-Path $tmp 'episode.heb.srt') 'Hebrew to English') (Join-Path $tmp 'episode.eng.srt') 'Hebrew output path'
        Assert-Equal (Get-OutputPath (Join-Path $tmp 'episode.en.srt') 'English to Hebrew') (Join-Path $tmp 'episode.heb.srt') 'English output path'

        $knownAsL = -join @(
            [char]0x05D9, [char]0x05D3, [char]0x05D5, [char]0x05E2,
            ' ',
            [char]0x05D2, [char]0x05DD,
            ' ',
            [char]0x05DB, '-L.'
        )
        $shalom = -join @([char]0x05E9, [char]0x05DC, [char]0x05D5, [char]0x05DD)
        $olam = -join @([char]0x05E2, [char]0x05D5, [char]0x05DC, [char]0x05DD)
        $bdika = -join @([char]0x05D1, [char]0x05D3, [char]0x05D9, [char]0x05E7, [char]0x05D4)

        $sample = "1`n00:00:01,000 --> 00:00:02,000`n<i>$knownAsL</i>"
        $fixed = Clean-AndFixRtl $sample
        Assert-True ($fixed.Contains([string]$RLI)) 'RTL isolate marker exists'
        Assert-True ($fixed.Contains([string]$LRI)) 'LTR isolate marker exists'
        Assert-True ($fixed.Contains([string]$PDI)) 'PDI marker exists'

        $items = Convert-SrtToTranslationItems "1`n00:00:01,000 --> 00:00:02,000`n$shalom`n$olam`n`n2`n00:00:03,000 --> 00:00:04,000`n$bdika"
        Assert-Equal $items.Count 2 'SRT parsing count'
        Assert-True ($items[0].Text.Contains(" `n ")) 'SRT line placeholder'

        $oneItem = Convert-SrtToTranslationItems "1`n00:00:01,000 --> 00:00:02,000`n$shalom"
        Assert-Equal $oneItem.Count 1 'Single SRT block parsing count'
        Assert-Equal $oneItem[0].Text $shalom 'Single SRT block text'

        $hebrewSrtPath = Join-Path $tmp 'sample.heb.srt'
        [System.IO.File]::WriteAllText($hebrewSrtPath, "1`n00:00:01,000 --> 00:00:02,000`n$shalom $olam $bdika $shalom $olam $bdika $shalom $olam $bdika")
        $hebrewProfile = Get-SubtitleLanguageProfile ([System.IO.File]::ReadAllText($hebrewSrtPath))
        Assert-Equal $hebrewProfile.LikelyLanguage 'Hebrew' 'Hebrew profile detection'
        $hebrewGuard = Test-TranslationDirectionLooksValid $hebrewSrtPath 'English to Hebrew'
        Assert-True (-not $hebrewGuard.IsValid) 'Hebrew wrong-direction guard'

        $englishSrtPath = Join-Path $tmp 'sample.eng.srt'
        [System.IO.File]::WriteAllText($englishSrtPath, "1`n00:00:01,000 --> 00:00:02,000`nThis is a normal English subtitle line with enough letters to detect the language.")
        $englishProfile = Get-SubtitleLanguageProfile ([System.IO.File]::ReadAllText($englishSrtPath))
        Assert-Equal $englishProfile.LikelyLanguage 'English' 'English profile detection'
        $englishGuard = Test-TranslationDirectionLooksValid $englishSrtPath 'Hebrew to English'
        Assert-True (-not $englishGuard.IsValid) 'English wrong-direction guard'

        Assert-ThrowsLike { Convert-GeminiResponseToStringArray $null } 'empty response' 'Empty Gemini response'
        Assert-ThrowsLike { Convert-GeminiResponseToStringArray ([pscustomobject]@{}) } 'no candidates' 'Missing candidates response'
        Assert-ThrowsLike {
            Convert-GeminiResponseToStringArray ([pscustomobject]@{
                candidates = @([pscustomobject]@{ finishReason = 'MAX_TOKENS' })
            })
        } 'MAX_TOKENS' 'Non-stop Gemini response'
        Assert-ThrowsLike {
            Convert-GeminiResponseToStringArray ([pscustomobject]@{
                candidates = @([pscustomobject]@{
                    finishReason = 'STOP'
                    content = [pscustomobject]@{
                        parts = @([pscustomobject]@{ text = 'not json' })
                    }
                })
            })
        } 'invalid JSON' 'Invalid JSON Gemini response'

        $oneTranslation = Convert-GeminiResponseToStringArray ([pscustomobject]@{
            candidates = @([pscustomobject]@{
                finishReason = 'STOP'
                content = [pscustomobject]@{
                    parts = @([pscustomobject]@{ text = '["Tea"]' })
                }
            })
        })
        Assert-Equal $oneTranslation.Count 1 'Single Gemini translation count'
        Assert-Equal $oneTranslation[0] 'Tea' 'Single Gemini translation value'

        $resultPath = Join-Path $tmp 'result.txt'
        [System.IO.File]::WriteAllText($resultPath, 'C:\Temp\translated.eng.srt', [System.Text.Encoding]::UTF8)
        Assert-Equal (Read-WorkerResultFile $resultPath) 'C:\Temp\translated.eng.srt' 'Worker result reader'
        Assert-ThrowsLike { Read-WorkerResultFile '' } 'path is empty' 'Empty worker result path'
        Assert-ThrowsLike { Read-WorkerResultFile (Join-Path $tmp 'missing.txt') } 'is missing' 'Missing worker result path'

        'SELFTEST_OK'
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Show-CompletionDialog {
    param(
        [string]$OutputPath,
        [System.Windows.Forms.IWin32Window]$Owner = $null
    )

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Translation Complete'
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(540, 170)

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(16, 16)
    $label.Size = New-Object System.Drawing.Size(500, 55)
    $label.Text = "Created:`r`n$OutputPath"
    $dialog.Controls.Add($label)

    $folderButton = New-Object System.Windows.Forms.Button
    $folderButton.Location = New-Object System.Drawing.Point(16, 110)
    $folderButton.Size = New-Object System.Drawing.Size(120, 34)
    $folderButton.Text = 'Open Folder'
    $folderButton.Add_Click({
        Start-Process explorer.exe "/select,`"$OutputPath`""
        $dialog.Close()
    })
    $dialog.Controls.Add($folderButton)

    $fileButton = New-Object System.Windows.Forms.Button
    $fileButton.Location = New-Object System.Drawing.Point(150, 110)
    $fileButton.Size = New-Object System.Drawing.Size(120, 34)
    $fileButton.Text = 'Open File'
    $fileButton.Add_Click({
        Start-Process -FilePath $OutputPath
        $dialog.Close()
    })
    $dialog.Controls.Add($fileButton)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Location = New-Object System.Drawing.Point(400, 110)
    $okButton.Size = New-Object System.Drawing.Size(120, 34)
    $okButton.Text = 'OK'
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.AcceptButton = $okButton
    $dialog.CancelButton = $okButton
    $dialog.Controls.Add($okButton)

    if ($Owner) {
        [void]$dialog.ShowDialog($Owner)
    } else {
        [void]$dialog.ShowDialog()
    }
}

function Quote-ProcessArgument {
    param([string]$Value)
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Show-MainForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $AppName
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(720, 520)
    $form.MinimumSize = New-Object System.Drawing.Size(720, 520)

    $fileLabel = New-Object System.Windows.Forms.Label
    $fileLabel.Location = New-Object System.Drawing.Point(16, 20)
    $fileLabel.Size = New-Object System.Drawing.Size(90, 24)
    $fileLabel.Text = 'SRT file:'
    $form.Controls.Add($fileLabel)

    $fileText = New-Object System.Windows.Forms.TextBox
    $fileText.Location = New-Object System.Drawing.Point(110, 18)
    $fileText.Size = New-Object System.Drawing.Size(465, 24)
    $form.Controls.Add($fileText)

    $browseButton = New-Object System.Windows.Forms.Button
    $browseButton.Location = New-Object System.Drawing.Point(590, 16)
    $browseButton.Size = New-Object System.Drawing.Size(95, 28)
    $browseButton.Text = 'Browse...'
    $form.Controls.Add($browseButton)

    $directionLabel = New-Object System.Windows.Forms.Label
    $directionLabel.Location = New-Object System.Drawing.Point(16, 62)
    $directionLabel.Size = New-Object System.Drawing.Size(90, 24)
    $directionLabel.Text = 'Direction:'
    $form.Controls.Add($directionLabel)

    $directionCombo = New-Object System.Windows.Forms.ComboBox
    $directionCombo.Location = New-Object System.Drawing.Point(110, 60)
    $directionCombo.Size = New-Object System.Drawing.Size(220, 24)
    $directionCombo.DropDownStyle = 'DropDownList'
    [void]$directionCombo.Items.Add('Hebrew to English')
    [void]$directionCombo.Items.Add('English to Hebrew')
    $directionCombo.SelectedIndex = 0
    $form.Controls.Add($directionCombo)

    $translateButton = New-Object System.Windows.Forms.Button
    $translateButton.Location = New-Object System.Drawing.Point(350, 57)
    $translateButton.Size = New-Object System.Drawing.Size(110, 32)
    $translateButton.Text = 'Translate'
    $form.Controls.Add($translateButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Location = New-Object System.Drawing.Point(475, 57)
    $cancelButton.Size = New-Object System.Drawing.Size(90, 32)
    $cancelButton.Text = 'Cancel'
    $cancelButton.Enabled = $false
    $form.Controls.Add($cancelButton)

    $resetKeyButton = New-Object System.Windows.Forms.Button
    $resetKeyButton.Location = New-Object System.Drawing.Point(580, 57)
    $resetKeyButton.Size = New-Object System.Drawing.Size(110, 32)
    $resetKeyButton.Text = 'Reset API Key'
    $form.Controls.Add($resetKeyButton)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(16, 105)
    $progress.Size = New-Object System.Drawing.Size(670, 22)
    $form.Controls.Add($progress)

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Location = New-Object System.Drawing.Point(16, 145)
    $logBox.Size = New-Object System.Drawing.Size(670, 315)
    $logBox.Multiline = $true
    $logBox.ScrollBars = 'Vertical'
    $logBox.ReadOnly = $true
    $form.Controls.Add($logBox)

    $appendLog = {
        param([string]$Message)
        $line = "[$(Get-Date -Format HH:mm:ss)] $Message`r`n"
        if ($logBox) {
            $logBox.AppendText($line)
        } else {
            [Console]::Error.WriteLine($line.TrimEnd())
        }
    }

    $setProgress = {
        param([int]$Value)
        $progress.Value = [Math]::Max(0, [Math]::Min(100, $Value))
    }

    $script:currentProcess = $null
    $script:currentTimer = $null
    $script:cancelRequested = $false
    $script:logReadLength = 0
    $script:currentJobDir = $null
    $script:currentLogFile = $null
    $script:currentProgressFile = $null
    $script:currentResultFile = $null
    $script:currentDoneFile = $null

    $browseButton.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = 'SRT subtitles (*.srt)|*.srt|All files (*.*)|*.*'
        $dialog.Title = 'Select SRT file'
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $fileText.Text = $dialog.FileName
        }
    })

    $resetKeyButton.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Reset the saved Gemini API key?`r`n`r`nYou will need to enter it again before translating.",
            $AppName,
            [System.Windows.Forms.MessageBoxButtons]::OKCancel,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($confirm -ne [System.Windows.Forms.DialogResult]::OK) {
            return
        }

        if (Test-Path -LiteralPath $KeyFile) {
            Remove-Item -LiteralPath $KeyFile -Force
        }
        [void](Show-ApiKeyDialog)
    })

    $cancelButton.Add_Click({
        $script:cancelRequested = $true
        if ($script:currentProcess -and -not $script:currentProcess.HasExited) {
            try {
                $script:currentProcess.Kill()
            } catch {
            }
        }
        if ($script:currentTimer) {
            $script:currentTimer.Stop()
            $script:currentTimer.Dispose()
            $script:currentTimer = $null
        }
        $cancelButton.Enabled = $false
        $cancelButton.Text = 'Cancel'
        $translateButton.Enabled = $true
        $browseButton.Enabled = $true
        $resetKeyButton.Enabled = $true
        $script:currentProcess = $null
        & $appendLog 'Cancel requested.'
        & $appendLog 'Canceled.'
                [System.Windows.Forms.MessageBox]::Show(
                    $form,
                    'Translation canceled. No output file was written.',
                    $AppName,
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                ) | Out-Null
    })

    $translateButton.Add_Click({
        try {
            $inputPath = $fileText.Text.Trim()
            if (-not $inputPath -or -not (Test-Path -LiteralPath $inputPath)) {
                [System.Windows.Forms.MessageBox]::Show(
                    $form,
                    'Please select an existing .srt file.',
                    $AppName,
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null
                return
            }

            $apiKey = Get-ApiKey
            if (-not $apiKey) {
                return
            }

            $direction = [string]$directionCombo.SelectedItem
            $directionCheck = Test-TranslationDirectionLooksValid -InputPath $inputPath -Direction $direction
            if (-not $directionCheck.IsValid) {
                [System.Windows.Forms.MessageBox]::Show(
                    $form,
                    $directionCheck.Message,
                    $AppName,
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null
                return
            }

            $translateButton.Enabled = $false
            $browseButton.Enabled = $false
            $resetKeyButton.Enabled = $false
            $cancelButton.Enabled = $true
            $cancelButton.Text = 'Cancel'
            $progress.Value = 0
            $logBox.Clear()

            & $appendLog "Input: $inputPath"
            & $appendLog "Direction: $direction"

            Ensure-ConfigDir
            $jobsDir = Join-Path $ConfigDir 'jobs'
            if (-not (Test-Path -LiteralPath $jobsDir)) {
                New-Item -ItemType Directory -Path $jobsDir -Force | Out-Null
            }

            $script:currentJobDir = Join-Path $jobsDir ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:currentJobDir -Force | Out-Null

            $script:currentLogFile = Join-Path $script:currentJobDir 'log.txt'
            $script:currentProgressFile = Join-Path $script:currentJobDir 'progress.txt'
            $script:currentResultFile = Join-Path $script:currentJobDir 'result.txt'
            $script:currentDoneFile = Join-Path $script:currentJobDir 'done.txt'
            [System.IO.File]::WriteAllText($script:currentLogFile, '', [System.Text.Encoding]::UTF8)
            [System.IO.File]::WriteAllText($script:currentProgressFile, '0', [System.Text.Encoding]::UTF8)
            $script:logReadLength = 0
            $script:cancelRequested = $false

            $powershellExe = (Get-Command powershell.exe).Source
            $arguments = @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', (Quote-ProcessArgument $PSCommandPath),
                '-WorkerMode',
                '-InputPath', (Quote-ProcessArgument $inputPath),
                '-Direction', (Quote-ProcessArgument $direction),
                '-LogFile', (Quote-ProcessArgument $script:currentLogFile),
                '-ProgressFile', (Quote-ProcessArgument $script:currentProgressFile),
                '-ResultFile', (Quote-ProcessArgument $script:currentResultFile),
                '-DoneFile', (Quote-ProcessArgument $script:currentDoneFile)
            ) -join ' '

            $script:currentProcess = Start-Process `
                -FilePath $powershellExe `
                -ArgumentList $arguments `
                -WindowStyle Hidden `
                -PassThru

            $timer = New-Object System.Windows.Forms.Timer
            $timer.Interval = 500
            $script:currentTimer = $timer
            $timer.Add_Tick({
                try {
                    if (Test-Path -LiteralPath $script:currentLogFile) {
                        $logText = [System.IO.File]::ReadAllText($script:currentLogFile)
                        if ($logText.Length -gt $script:logReadLength) {
                            $logBox.AppendText($logText.Substring($script:logReadLength).Replace("`n", "`r`n"))
                            $script:logReadLength = $logText.Length
                        }
                    }

                    if (Test-Path -LiteralPath $script:currentProgressFile) {
                        $progressText = ([System.IO.File]::ReadAllText($script:currentProgressFile)).Trim()
                        $progressValue = 0
                        if ([int]::TryParse($progressText, [ref]$progressValue)) {
                            & $setProgress $progressValue
                        }
                    }

                    $finished = (Test-Path -LiteralPath $script:currentDoneFile) -or ($script:currentProcess -and $script:currentProcess.HasExited)
                    if (-not $finished) {
                        return
                    }

                    $timer.Stop()
                    $timer.Dispose()
                    $script:currentTimer = $null

                    if ($script:cancelRequested) {
                        & $appendLog 'Canceled.'
                        [System.Windows.Forms.MessageBox]::Show(
                            $form,
                            'Translation canceled. No output file was written.',
                            $AppName,
                            [System.Windows.Forms.MessageBoxButtons]::OK,
                            [System.Windows.Forms.MessageBoxIcon]::Information
                        ) | Out-Null
                    } elseif (Test-Path -LiteralPath $script:currentDoneFile) {
                        $doneText = [System.IO.File]::ReadAllText($script:currentDoneFile)
                        if ($doneText.StartsWith('OK')) {
                            & $setProgress 100
                            $output = Read-WorkerResultFile $script:currentResultFile
                            & $appendLog "Done: $output"
                            Show-CompletionDialog -OutputPath $output -Owner $form
                        } else {
                            $message = ($doneText -replace '^ERROR\s*', '').Trim()
                            if (-not $message) {
                                $message = 'Translation failed.'
                            }
                            & $appendLog "Error: $message"
                            [System.Windows.Forms.MessageBox]::Show(
                                $form,
                                $message,
                                $AppName,
                                [System.Windows.Forms.MessageBoxButtons]::OK,
                                [System.Windows.Forms.MessageBoxIcon]::Error
                            ) | Out-Null
                        }
                    } else {
                        & $appendLog 'Error: worker process exited unexpectedly.'
                        [System.Windows.Forms.MessageBox]::Show(
                            $form,
                            'Translation process exited unexpectedly.',
                            $AppName,
                            [System.Windows.Forms.MessageBoxButtons]::OK,
                            [System.Windows.Forms.MessageBoxIcon]::Error
                        ) | Out-Null
                    }

                    $translateButton.Enabled = $true
                    $browseButton.Enabled = $true
                    $resetKeyButton.Enabled = $true
                    $cancelButton.Enabled = $false
                    $cancelButton.Text = 'Cancel'
                    $script:currentProcess = $null
                } catch {
                    & $appendLog (Format-ErrorDetails $_)
                    if ($script:currentTimer) {
                        $script:currentTimer.Stop()
                        $script:currentTimer.Dispose()
                        $script:currentTimer = $null
                    }
                    $translateButton.Enabled = $true
                    $browseButton.Enabled = $true
                    $resetKeyButton.Enabled = $true
                    $cancelButton.Enabled = $false
                    $cancelButton.Text = 'Cancel'
                    $script:currentProcess = $null
                }
            })
            $timer.Start()
        } catch {
            $translateButton.Enabled = $true
            $browseButton.Enabled = $true
            $resetKeyButton.Enabled = $true
            $cancelButton.Enabled = $false
            $cancelButton.Text = 'Cancel'
            & $appendLog "Error: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                $_.Exception.Message,
                $AppName,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    })

    [void]$form.ShowDialog()
}

if ($RunSelfTests) {
    Invoke-SelfTests
} elseif ($MockWorkerMode) {
    Invoke-MockWorkerMode
} elseif ($WorkerMode) {
    Invoke-WorkerMode
} else {
    Show-MainForm
}
