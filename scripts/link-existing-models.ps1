[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('find', 'link')]
    [string]$Command,

    [string]$ComfyRoot,
    [string]$ModelsDir,
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ExpectedSizeCache = @{}

function Get-DefaultModelsDir {
    $localAppData = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = Join-Path $HOME 'AppData\Local'
    }
    return Join-Path $localAppData 'LTXDesktop\models'
}

function New-ModelSpec {
    param(
        [string]$ModelId,
        [string]$RelativePath,
        [bool]$IsFolder,
        [Int64]$ExpectedSizeBytes,
        [string]$RepoId,
        [string]$Description
    )

    return [pscustomobject]@{
        ModelId = $ModelId
        RelativePath = $RelativePath
        Name = Split-Path -Path $RelativePath -Leaf
        IsFolder = $IsFolder
        ExpectedSizeBytes = $ExpectedSizeBytes
        RepoId = $RepoId
        Description = $Description
    }
}

function Get-ModelSpecs {
    return @(
        (New-ModelSpec -ModelId 'checkpoint' -RelativePath 'ltx-2.3-22b-distilled.safetensors' -IsFolder $false -ExpectedSizeBytes 43000000000 -RepoId 'Lightricks/LTX-2.3' -Description 'Main transformer model'),
        (New-ModelSpec -ModelId 'upsampler' -RelativePath 'ltx-2.3-spatial-upscaler-x2-1.0.safetensors' -IsFolder $false -ExpectedSizeBytes 1900000000 -RepoId 'Lightricks/LTX-2.3' -Description '2x upscaler'),
        (New-ModelSpec -ModelId 'distilled_lora' -RelativePath 'ltx-2-19b-distilled-lora-384.safetensors' -IsFolder $false -ExpectedSizeBytes 400000000 -RepoId 'Lightricks/LTX-2' -Description 'LoRA for Pro model'),
        (New-ModelSpec -ModelId 'ic_lora' -RelativePath 'ltx-2.3-22b-ic-lora-union-control-ref0.5.safetensors' -IsFolder $false -ExpectedSizeBytes 654465352 -RepoId 'Lightricks/LTX-2.3-22b-IC-LoRA-Union-Control' -Description 'Union IC-LoRA control model'),
        (New-ModelSpec -ModelId 'depth_processor' -RelativePath 'dpt-hybrid-midas' -IsFolder $true -ExpectedSizeBytes 500000000 -RepoId 'Intel/dpt-hybrid-midas' -Description 'DPT-Hybrid MiDaS depth processor'),
        (New-ModelSpec -ModelId 'person_detector' -RelativePath 'yolox_l.torchscript.pt' -IsFolder $false -ExpectedSizeBytes 217697649 -RepoId 'hr16/yolox-onnx' -Description 'YOLOX person detector'),
        (New-ModelSpec -ModelId 'pose_processor' -RelativePath 'dw-ll_ucoco_384_bs5.torchscript.pt' -IsFolder $false -ExpectedSizeBytes 135059124 -RepoId 'hr16/DWPose-TorchScript-BatchSize5' -Description 'DW Pose TorchScript processor'),
        (New-ModelSpec -ModelId 'text_encoder' -RelativePath 'gemma-3-12b-it-qat-q4_0-unquantized' -IsFolder $true -ExpectedSizeBytes 25000000000 -RepoId 'Lightricks/gemma-3-12b-it-qat-q4_0-unquantized' -Description 'Gemma text encoder'),
        (New-ModelSpec -ModelId 'zit' -RelativePath 'Z-Image-Turbo' -IsFolder $true -ExpectedSizeBytes 31000000000 -RepoId 'Tongyi-MAI/Z-Image-Turbo' -Description 'Z-Image-Turbo model')
    )
}

function ConvertTo-YamlString {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return "''"
    }

    return "'" + ($Value -replace "'", "''") + "'"
}

function ConvertFrom-YamlString {
    param([string]$Value)

    $trimmed = $Value.Trim()
    if ($trimmed.Length -ge 2 -and $trimmed.StartsWith("'") -and $trimmed.EndsWith("'")) {
        return $trimmed.Substring(1, $trimmed.Length - 2).Replace("''", "'")
    }
    return $trimmed
}

function Get-NormalizedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    try {
        return [System.IO.Path]::GetFullPath($Path)
    } catch {
        return $Path
    }
}

function Test-UncPath {
    param([string]$Path)

    return $Path.StartsWith('\\')
}

function Get-DriveRootOrEmpty {
    param([string]$Path)

    if ($Path -match '^[A-Za-z]:') {
        return $Path.Substring(0, 2).ToUpperInvariant()
    }
    return ''
}

function Resolve-ExpectedSizeBytes {
    param($Spec)

    if ($script:ExpectedSizeCache.ContainsKey($Spec.ModelId)) {
        return [Int64]$script:ExpectedSizeCache[$Spec.ModelId]
    }

    $resolved = [Int64]$Spec.ExpectedSizeBytes
    if (-not $Spec.IsFolder) {
        $relativeUrl = ($Spec.RelativePath -replace '\\', '/')
        $uri = "https://huggingface.co/$($Spec.RepoId)/resolve/main/$relativeUrl"

        try {
            $response = Invoke-WebRequest -Method Head -Uri $uri -MaximumRedirection 5 -TimeoutSec 15 -ErrorAction Stop
            $contentLength = $response.Headers['Content-Length']
            $parsed = 0L
            if ($contentLength -and [Int64]::TryParse([string]$contentLength, [ref]$parsed) -and $parsed -gt 0) {
                $resolved = $parsed
            }
        } catch {
            # Fall back to the repository's expected size metadata when remote metadata is unavailable.
        }
    }

    $script:ExpectedSizeCache[$Spec.ModelId] = $resolved
    return $resolved
}

function Get-ArtifactSizeBytes {
    param(
        [string]$Path,
        [bool]$IsFolder
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return 0L
    }

    if (-not $IsFolder) {
        return [Int64](Get-Item -LiteralPath $Path).Length
    }

    $sum = 0L
    Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
        $sum += [Int64]$_.Length
    }
    return $sum
}

function Get-SearchRoots {
    param(
        [string]$ComfyRoot,
        [string]$ModelsDir
    )

    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @($ComfyRoot, $ModelsDir)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $normalized = Get-NormalizedPath $candidate
        if ($roots.Contains($normalized)) {
            continue
        }

        if (Test-Path -LiteralPath $normalized) {
            $roots.Add($normalized)
        }
    }

    return $roots
}

function Get-CandidateNames {
    param($Spec)

    switch ($Spec.ModelId) {
        'zit' {
            return @('Z-Image-Turbo', 'Z-Image')
        }
        default {
            return @($Spec.Name)
        }
    }
}

function Test-IsLoraModel {
    param($Spec)

    return $Spec.ModelId -in @('distilled_lora', 'ic_lora')
}

function Get-PathSegmentsLower {
    param([string]$Path)

    return @($Path -split '[\\/]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.ToLowerInvariant() })
}

function Test-PathContainsSegment {
    param(
        [string]$Path,
        [string]$Segment
    )

    $segments = Get-PathSegmentsLower $Path
    return $segments -contains $Segment.ToLowerInvariant()
}

function Get-PreferredBaseSegments {
    param($Spec)

    switch ($Spec.ModelId) {
        'checkpoint' { return @('stable-diffusion', 'diffusion_models') }
        'upsampler' { return @('stable-diffusion', 'diffusion_models', 'latent_upscale_models') }
        'zit' { return @('diffusion_models', 'stable-diffusion') }
        'text_encoder' { return @('text_encoders', 'stable-diffusion', 'diffusion_models') }
        default { return @() }
    }
}

function Test-PreferredBaseLocation {
    param(
        $Spec,
        [string]$Path
    )

    $preferredSegments = Get-PreferredBaseSegments $Spec
    if ($preferredSegments.Count -eq 0) {
        return $false
    }

    foreach ($segment in $preferredSegments) {
        if (Test-PathContainsSegment -Path $Path -Segment $segment) {
            return $true
        }
    }

    return $false
}

function Test-RejectCandidate {
    param(
        $Spec,
        [string]$Path,
        [bool]$IsFolder,
        [Int64]$SizeBytes,
        [Int64]$ExpectedSizeBytes
    )

    if (-not (Test-IsLoraModel $Spec) -and (Test-PathContainsSegment -Path $Path -Segment 'lora')) {
        return $true
    }

    if ($Spec.ModelId -eq 'zit') {
        if (-not (Test-PreferredBaseLocation -Spec $Spec -Path $Path)) {
            return $true
        }

        if ($IsFolder -and $ExpectedSizeBytes -gt 0) {
            $minimumAcceptable = [Int64]([math]::Floor($ExpectedSizeBytes * 0.70))
            if ($SizeBytes -lt $minimumAcceptable) {
                return $true
            }
        }
    }

    return $false
}

function Get-CandidatesForSpec {
    param(
        $Spec,
        [System.Collections.Generic.List[string]]$SearchRoots,
        [string]$ModelsDir
    )

    $expectedSize = Resolve-ExpectedSizeBytes $Spec
    $canonicalTarget = Get-NormalizedPath (Join-Path $ModelsDir $Spec.RelativePath)
    $unique = @{}

    $candidateNames = Get-CandidateNames $Spec

    foreach ($root in $SearchRoots) {
        if ($Spec.IsFolder) {
            $items = Get-ChildItem -LiteralPath $root -Recurse -Force -Directory -ErrorAction SilentlyContinue |
                Where-Object { $candidateNames -contains $_.Name }
        } else {
            $items = foreach ($candidateName in $candidateNames) {
                Get-ChildItem -LiteralPath $root -Recurse -Force -File -Filter $candidateName -ErrorAction SilentlyContinue
            }
        }

        foreach ($item in $items) {
            $path = Get-NormalizedPath $item.FullName
            if ($unique.ContainsKey($path)) {
                continue
            }

            $sizeBytes = Get-ArtifactSizeBytes -Path $path -IsFolder $Spec.IsFolder
            if (Test-RejectCandidate -Spec $Spec -Path $path -IsFolder $Spec.IsFolder -SizeBytes $sizeBytes -ExpectedSizeBytes $expectedSize) {
                continue
            }

            $score = 100
            $reasons = New-Object System.Collections.Generic.List[string]
            $reasons.Add('exact-name')

            if (Test-PreferredBaseLocation -Spec $Spec -Path $path) {
                $score += 15
                $reasons.Add('preferred-base-location')
            }

            if ($path -eq $canonicalTarget) {
                $score += 50
                $reasons.Add('already-canonical')
            }

            if (Test-UncPath $path) {
                $reasons.Add('network-path')
            } else {
                $score += 5
                $reasons.Add('local-path')
            }

            $deltaRatio = 0.0
            if ($expectedSize -gt 0) {
                $deltaRatio = [math]::Abs($sizeBytes - $expectedSize) / [double]$expectedSize
                if ($deltaRatio -le 0.02) {
                    $score += 20
                    $reasons.Add('size-near-exact')
                } elseif ($deltaRatio -le 0.10) {
                    $score += 10
                    $reasons.Add('size-close')
                } elseif ($deltaRatio -le 0.25) {
                    $score += 4
                    $reasons.Add('size-approximate')
                } else {
                    $score -= 20
                    $reasons.Add('size-mismatch')
                }
            }

            $unique[$path] = [pscustomobject]@{
                Path = $path
                SizeBytes = $sizeBytes
                Score = $score
                ScoreReasons = ($reasons -join ',')
                DeltaRatio = $deltaRatio
            }
        }
    }

    return $unique.Values | Sort-Object @(
        @{ Expression = 'Score'; Descending = $true },
        @{ Expression = 'DeltaRatio'; Descending = $false },
        @{ Expression = 'Path'; Descending = $false }
    )
}

function Write-Manifest {
    param(
        [string]$ManifestPath,
        [string]$ComfyRoot,
        [string]$ModelsDir,
        [System.Collections.Generic.List[string]]$SearchRoots,
        [object[]]$Specs,
        [hashtable]$CandidatesByModelId
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# LTX model link manifest')
    $lines.Add('# For each model, the last uncommented selected_source line wins.')
    $lines.Add('version: 1')
    $lines.Add("generated_at: $(ConvertTo-YamlString ((Get-Date).ToString('o')))")
    $lines.Add("comfy_root: $(ConvertTo-YamlString $ComfyRoot)")
    $lines.Add("models_dir: $(ConvertTo-YamlString $ModelsDir)")
    $lines.Add('search_roots:')
    foreach ($root in $SearchRoots) {
        $lines.Add("  - $(ConvertTo-YamlString $root)")
    }
    $lines.Add('models:')

    foreach ($spec in $Specs) {
        $expectedSize = Resolve-ExpectedSizeBytes $spec
        $expectedTarget = Join-Path $ModelsDir $spec.RelativePath
        $artifactType = if ($spec.IsFolder) { 'directory' } else { 'file' }
        $candidates = @($CandidatesByModelId[$spec.ModelId])

        $lines.Add("  $($spec.ModelId):")
        $lines.Add("    expected_target: $(ConvertTo-YamlString $expectedTarget)")
        $lines.Add("    expected_name: $(ConvertTo-YamlString $spec.Name)")
        $lines.Add("    artifact_type: $(ConvertTo-YamlString $artifactType)")
        $lines.Add("    repo_id: $(ConvertTo-YamlString $spec.RepoId)")
        $lines.Add("    expected_size_bytes: $expectedSize")

        if ($candidates.Count -gt 0) {
            $selected = $candidates[0]
            $lines.Add("    selected_source: $(ConvertTo-YamlString $selected.Path)")
            $lines.Add("    selected_size_bytes: $($selected.SizeBytes)")
            $lines.Add("    selected_reasons: $(ConvertTo-YamlString $selected.ScoreReasons)")

            for ($index = 1; $index -lt $candidates.Count; $index++) {
                $candidate = $candidates[$index]
                $lines.Add("    # selected_source: $(ConvertTo-YamlString $candidate.Path)")
                $lines.Add("    # selected_size_bytes: $($candidate.SizeBytes)")
                $lines.Add("    # selected_reasons: $(ConvertTo-YamlString $candidate.ScoreReasons)")
            }
        } else {
            $lines.Add("    selected_source: ''")
            $lines.Add('    selected_size_bytes: 0')
            $lines.Add("    selected_reasons: $(ConvertTo-YamlString 'no-match-found')")
        }
    }

    $parent = Split-Path -Parent $ManifestPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Set-Content -LiteralPath $ManifestPath -Value $lines -Encoding UTF8
}

function Read-Manifest {
    param([string]$ManifestPath)

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "Manifest not found: $ManifestPath"
    }

    $result = [ordered]@{
        ModelsDir = ''
        SelectedSources = @{}
    }

    $currentModelId = ''
    foreach ($line in Get-Content -LiteralPath $ManifestPath) {
        if ($line -match '^models_dir:\s+(.+)$') {
            $result.ModelsDir = ConvertFrom-YamlString $Matches[1]
            continue
        }

        if ($line -match '^  ([a-z_]+):\s*$') {
            $currentModelId = $Matches[1]
            continue
        }

        if ([string]::IsNullOrWhiteSpace($currentModelId)) {
            continue
        }

        if ($line -match '^    selected_source:\s+(.+)$') {
            $result.SelectedSources[$currentModelId] = ConvertFrom-YamlString $Matches[1]
        }
    }

    return [pscustomobject]$result
}

function Remove-ExistingTarget {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    } else {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Get-LinkMode {
    param(
        $Spec,
        [string]$SourcePath,
        [string]$TargetPath
    )

    $sourceRoot = Get-DriveRootOrEmpty $SourcePath
    $targetRoot = Get-DriveRootOrEmpty $TargetPath
    $sourceIsUnc = Test-UncPath $SourcePath

    if ($Spec.IsFolder) {
        if (-not $sourceIsUnc) {
            return 'Junction'
        }
        return 'SymbolicLink'
    }

    if (-not $sourceIsUnc -and $sourceRoot -ne '' -and $sourceRoot -eq $targetRoot) {
        return 'HardLink'
    }

    return 'SymbolicLink'
}

function Test-HardLinkPair {
    param(
        [string]$SourcePath,
        [string]$TargetPath
    )

    $output = & fsutil hardlink list $TargetPath 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    $normalizedSource = Get-NormalizedPath $SourcePath
    $targetDrive = Get-DriveRootOrEmpty $TargetPath
    foreach ($line in ($output -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        if ($trimmed.StartsWith('\') -and -not $trimmed.StartsWith('\\') -and $targetDrive -ne '') {
            $trimmed = "$targetDrive$trimmed"
        }

        if ((Get-NormalizedPath $trimmed) -eq $normalizedSource) {
            return $true
        }
    }

    return $false
}

function Validate-Link {
    param(
        $Spec,
        [string]$SourcePath,
        [string]$TargetPath,
        [string]$LinkMode
    )

    if (-not (Test-Path -LiteralPath $TargetPath)) {
        throw "Link target missing after creation: $TargetPath"
    }

    if ($LinkMode -eq 'HardLink') {
        if (-not (Test-HardLinkPair -SourcePath $SourcePath -TargetPath $TargetPath)) {
            throw "Hardlink validation failed for $TargetPath"
        }
        return
    }

    $targetItem = Get-Item -LiteralPath $TargetPath -Force
    $resolvedTarget = ''
    if ($null -ne $targetItem.PSObject.Properties['LinkTarget'] -and -not [string]::IsNullOrWhiteSpace([string]$targetItem.LinkTarget)) {
        $resolvedTarget = Get-NormalizedPath ([string]$targetItem.LinkTarget)
    } elseif ($null -ne $targetItem.PSObject.Properties['Target'] -and -not [string]::IsNullOrWhiteSpace([string]$targetItem.Target)) {
        $resolvedTarget = Get-NormalizedPath ([string]$targetItem.Target)
    } elseif ($null -ne $targetItem.PSObject.Properties['ResolvedTarget'] -and -not [string]::IsNullOrWhiteSpace([string]$targetItem.ResolvedTarget)) {
        $resolvedTarget = Get-NormalizedPath ([string]$targetItem.ResolvedTarget)
    } else {
        $resolvedTarget = Get-NormalizedPath ((Resolve-Path -LiteralPath $TargetPath).Path)
    }

    $resolvedSource = Get-NormalizedPath $SourcePath

    if ($resolvedTarget -ne $resolvedSource) {
        throw "Link validation failed for $TargetPath (resolved to $resolvedTarget, expected $resolvedSource)"
    }

    if ($LinkMode -eq 'SymbolicLink') {
        return
    }

    $targetSize = Get-ArtifactSizeBytes -Path $TargetPath -IsFolder $Spec.IsFolder
    $sourceSize = Get-ArtifactSizeBytes -Path $SourcePath -IsFolder $Spec.IsFolder
    if ($targetSize -ne $sourceSize) {
        throw "Link validation failed for $TargetPath (size $targetSize does not match $sourceSize)"
    }
}

function Invoke-FindCommand {
    param(
        [string]$ComfyRoot,
        [string]$ModelsDir,
        [string]$ManifestPath
    )

    if ([string]::IsNullOrWhiteSpace($ComfyRoot)) {
        throw 'The find command requires -ComfyRoot.'
    }

    $normalizedComfyRoot = Get-NormalizedPath $ComfyRoot
    if (-not (Test-Path -LiteralPath $normalizedComfyRoot)) {
        throw "Comfy root not found: $normalizedComfyRoot"
    }

    $normalizedModelsDir = Get-NormalizedPath $ModelsDir
    $searchRoots = Get-SearchRoots -ComfyRoot $normalizedComfyRoot -ModelsDir $normalizedModelsDir
    $specs = Get-ModelSpecs
    $candidatesByModelId = @{}

    foreach ($spec in $specs) {
        $candidatesByModelId[$spec.ModelId] = @(Get-CandidatesForSpec -Spec $spec -SearchRoots $searchRoots -ModelsDir $normalizedModelsDir)
    }

    Write-Manifest -ManifestPath $ManifestPath -ComfyRoot $normalizedComfyRoot -ModelsDir $normalizedModelsDir -SearchRoots $searchRoots -Specs $specs -CandidatesByModelId $candidatesByModelId
    Write-Host "Manifest written to $ManifestPath" -ForegroundColor Green
}

function Invoke-LinkCommand {
    param([string]$ManifestPath)

    $manifest = Read-Manifest -ManifestPath $ManifestPath
    $modelsDir = Get-NormalizedPath $manifest.ModelsDir
    if ([string]::IsNullOrWhiteSpace($modelsDir)) {
        throw "Manifest is missing models_dir: $ManifestPath"
    }

    New-Item -ItemType Directory -Path $modelsDir -Force | Out-Null

    $selectedBySource = @{}
    $specs = Get-ModelSpecs
    foreach ($spec in $specs) {
        $selected = [string]($manifest.SelectedSources[$spec.ModelId])
        if ([string]::IsNullOrWhiteSpace($selected)) {
            continue
        }

        $normalizedSource = Get-NormalizedPath $selected
        if ($selectedBySource.ContainsKey($normalizedSource)) {
            throw "The same source path is selected for multiple model IDs: $normalizedSource"
        }
        $selectedBySource[$normalizedSource] = $spec.ModelId
    }

    foreach ($spec in $specs) {
        $selected = [string]($manifest.SelectedSources[$spec.ModelId])
        if ([string]::IsNullOrWhiteSpace($selected)) {
            Write-Host "Skipping $($spec.ModelId): no selected source" -ForegroundColor Yellow
            continue
        }

        $sourcePath = Get-NormalizedPath $selected
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            throw "Selected source for $($spec.ModelId) does not exist: $sourcePath"
        }

        $sourceIsDirectory = (Get-Item -LiteralPath $sourcePath -Force).PSIsContainer
        if ([bool]$sourceIsDirectory -ne [bool]$spec.IsFolder) {
            throw "Selected source type mismatch for $($spec.ModelId): $sourcePath"
        }

        $targetPath = Get-NormalizedPath (Join-Path $modelsDir $spec.RelativePath)
        if ($targetPath -eq $sourcePath) {
            Write-Host "Keeping $($spec.ModelId): source is already the canonical target" -ForegroundColor Cyan
            continue
        }

        $parent = Split-Path -Parent $targetPath
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        Remove-ExistingTarget -Path $targetPath
        $linkMode = Get-LinkMode -Spec $spec -SourcePath $sourcePath -TargetPath $targetPath

        Write-Host "Linking $($spec.ModelId) via $linkMode" -ForegroundColor Cyan
        switch ($linkMode) {
            'HardLink' {
                New-Item -ItemType HardLink -Path $targetPath -Target $sourcePath | Out-Null
            }
            'Junction' {
                New-Item -ItemType Junction -Path $targetPath -Target $sourcePath | Out-Null
            }
            'SymbolicLink' {
                New-Item -ItemType SymbolicLink -Path $targetPath -Target $sourcePath | Out-Null
            }
            default {
                throw "Unsupported link mode: $linkMode"
            }
        }

        Validate-Link -Spec $spec -SourcePath $sourcePath -TargetPath $targetPath -LinkMode $linkMode
    }

    Write-Host "Linking complete for $modelsDir" -ForegroundColor Green
}

if ([string]::IsNullOrWhiteSpace($ModelsDir)) {
    $ModelsDir = Get-DefaultModelsDir
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $ModelsDir 'ltx-model-links.yaml'
}

switch ($Command) {
    'find' {
        Invoke-FindCommand -ComfyRoot $ComfyRoot -ModelsDir $ModelsDir -ManifestPath $ManifestPath
    }
    'link' {
        Invoke-LinkCommand -ManifestPath $ManifestPath
    }
    default {
        throw "Unsupported command: $Command"
    }
}