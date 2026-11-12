# Юніт-тести архіву запуску: Save-IaSnapshotArchive, Read-IaSnapshotArchive, Remove-IaExpiredArchives (потік Collector).
BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	$script:Module = Get-Module IndexAdvisor
	Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.ZipFile -ErrorAction SilentlyContinue
	$script:RunId = '0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b'
	function New-ColTestPrompt {
		param([string]$TemplateId = 'index-analysis', [int]$Version = 1)
		return [ordered]@{
			templateId = $TemplateId
			templateVersion = $Version
			messages = @([ordered]@{ role = 'system'; content = 'system prompt' }, [ordered]@{ role = 'user'; content = '{"tables":[]}' })
			toolSchemas = @()
			responseSchema = [ordered]@{ type = 'object' }
		}
	}
	function Save-ColTestArchive {
		param($Snapshot, $Prompts, $MaskingMap, $Config)
		& $script:Module {
			param($s, $p, $m, $r, $c)
			Save-IaSnapshotArchive -Snapshot $s -Prompts $p -MaskingMap $m -RunId $r -Config $c
		} $Snapshot $Prompts $MaskingMap $script:RunId $Config
	}
	function Get-ColTestZipEntries {
		param([string]$Path)
		$zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
		try {
			return @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') } | Sort-Object)
		}
		finally {
			$zip.Dispose()
		}
	}
}

Describe 'Save-IaSnapshotArchive' {
	BeforeEach {
		$script:Root = Join-Path (Get-PSDrive TestDrive).Root ([guid]::NewGuid().ToString('N'))
		$script:Config = Get-IaTestConfig -Root $script:Root
	}

	It 'archive.enabled = false — повертає $null і нічого не створює' {
		$script:Config.archive.enabled = $false
		$path = Save-ColTestArchive -Snapshot (Get-IaTestSnapshot) -Prompts @(New-ColTestPrompt) -Config $script:Config
		$path | Should -BeNullOrEmpty
		Test-Path -LiteralPath $script:Config.archive.path | Should -BeFalse
	}

	It 'створює один ZIP з manifest.json, snapshot.json і prompts/<templateId>.json; мапа — поруч, не всередині' {
		$map = [ordered]@{ servers = [ordered]@{ srv1 = 'SQL01' }; tables = [ordered]@{ tbl1 = 'Orders' } }
		$snapshot = Get-IaTestSnapshot
		$snapshot.masking.namesMasked = $true
		$snapshot.masking.literalsMasked = $true
		$prompts = @((New-ColTestPrompt), (New-ColTestPrompt -TemplateId 'partition-analysis' -Version 2))
		$path = Save-ColTestArchive -Snapshot $snapshot -Prompts $prompts -MaskingMap $map -Config $script:Config
		$path | Should -Exist
		Split-Path -Leaf $path | Should -Match '^\d{8}_\d{6}_AGL-SALES_0f1e2d3c\.zip$'
		@(Get-ChildItem -LiteralPath $script:Config.archive.path -Filter '*.zip').Count | Should -Be 1
		Get-ColTestZipEntries -Path $path | Should -Be @('manifest.json', 'prompts/index-analysis.json', 'prompts/partition-analysis.json', 'snapshot.json')
		$mapPath = $path -replace '\.zip$', '.map.json'
		$mapPath | Should -Exist
		(Get-Content -LiteralPath $mapPath -Raw | ConvertFrom-Json -AsHashtable).tables.tbl1 | Should -Be 'Orders'
		@(Get-ChildItem -LiteralPath $script:Config.archive.path -Force | Where-Object Name -Like '.staging_*').Count | Should -Be 0
	}

	It 'manifest містить runId, snapshotId, версії шаблонів і позначки маскування' {
		$snapshot = Get-IaTestSnapshot
		$snapshot.masking.namesMasked = $true
		$path = Save-ColTestArchive -Snapshot $snapshot -Prompts @(New-ColTestPrompt -Version 3) -Config $script:Config
		$archive = & $script:Module { param($p) Read-IaSnapshotArchive -Path $p } $path
		$manifest = $archive.manifest
		$manifest.schemaVersion | Should -Be '1.0'
		$manifest.runId | Should -Be $script:RunId
		$manifest.snapshotId | Should -Be $snapshot.snapshotId
		$manifest.requestedServer | Should -Be 'AGL-SALES'
		$manifest.namesMasked | Should -BeTrue
		$manifest.literalsMasked | Should -BeFalse
		$manifest.promptTemplates[0].id | Should -Be 'index-analysis'
		$manifest.promptTemplates[0].version | Should -Be 3
		$manifest.warning | Should -BeNullOrEmpty
		$manifest.createdAtUtc | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$'
		$manifest.toolVersion | Should -Not -BeNullOrEmpty
	}

	It 'без маскування імен — manifest.warning і Write-Warning про немасковані дані' {
		$path = Save-ColTestArchive -Snapshot (Get-IaTestSnapshot) -Prompts @(New-ColTestPrompt) -Config $script:Config 3>$null
		$archive = & $script:Module { param($p) Read-IaSnapshotArchive -Path $p -WarningAction SilentlyContinue } $path
		$archive.manifest.namesMasked | Should -BeFalse
		$archive.manifest.warning | Should -Match 'немасковані'
		$saveWarnings = & $script:Module {
			param($s, $p, $r, $c)
			Save-IaSnapshotArchive -Snapshot $s -Prompts $p -RunId $r -Config $c 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
		} (Get-IaTestSnapshot) @(New-ColTestPrompt) $script:RunId $script:Config
		@($saveWarnings).Count | Should -BeGreaterThan 0
		$saveWarnings[0].Message | Should -Match 'не можна передавати в зовнішні сервіси'
	}

	It 'без мапи маскування файл .map.json не створюється' {
		$path = Save-ColTestArchive -Snapshot (Get-IaTestSnapshot) -Prompts @(New-ColTestPrompt) -Config $script:Config 3>$null
		($path -replace '\.zip$', '.map.json') | Should -Not -Exist
	}

	It 'каталог створюється з обмеженням NTFS: без успадкування, лише користувач, SYSTEM і Administrators' -Skip:(-not $IsWindows) {
		$null = Save-ColTestArchive -Snapshot (Get-IaTestSnapshot) -Prompts @(New-ColTestPrompt) -Config $script:Config 3>$null
		$acl = Get-Acl -LiteralPath $script:Config.archive.path
		$acl.AreAccessRulesProtected | Should -BeTrue
		$sids = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
		$expected = @([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544') | Sort-Object -Unique
		$sids | Should -Be $expected
	}

	It 'archive.restrictAcl = false — права не змінюються' -Skip:(-not $IsWindows) {
		$script:Config.archive.restrictAcl = $false
		$null = Save-ColTestArchive -Snapshot (Get-IaTestSnapshot) -Prompts @(New-ColTestPrompt) -Config $script:Config 3>$null
		(Get-Acl -LiteralPath $script:Config.archive.path).AreAccessRulesProtected | Should -BeFalse
	}
}

Describe 'Read-IaSnapshotArchive' {
	BeforeEach {
		$script:Root = Join-Path (Get-PSDrive TestDrive).Root ([guid]::NewGuid().ToString('N'))
		$script:Config = Get-IaTestConfig -Root $script:Root
	}

	It 'повертає manifest, snapshot, prompts і мапу маскування з файлу поруч' {
		$snapshot = Get-IaTestSnapshot
		$snapshot.masking.namesMasked = $true
		$snapshot.instances[0].sqlserverStartTimeUtc = '2026-09-01T03:00:00.000Z'
		$map = [ordered]@{ tables = [ordered]@{ tbl1 = 'Orders' } }
		$path = Save-ColTestArchive -Snapshot $snapshot -Prompts @(New-ColTestPrompt) -MaskingMap $map -Config $script:Config
		$archive = & $script:Module { param($p) Read-IaSnapshotArchive -Path $p } $path
		$archive.snapshot.snapshotId | Should -Be $snapshot.snapshotId
		@($archive.snapshot.instances).Count | Should -Be 2
		@($archive.prompts).Count | Should -Be 1
		$archive.prompts[0].templateId | Should -Be 'index-analysis'
		$archive.maskingMap.tables.tbl1 | Should -Be 'Orders'
		$archive.snapshot.collectedAtUtc | Should -BeOfType [string]
		$archive.snapshot.instances[0].sqlserverStartTimeUtc | Should -BeExactly '2026-09-01T03:00:00.000Z'
		$json = $archive.snapshot | ConvertTo-Json -Depth 50
		Test-IaJsonAgainstSchema -Json $json -Schema snapshot | Should -BeTrue
	}

	It 'без мапи поруч — maskingMap = $null' {
		$snapshot = Get-IaTestSnapshot
		$snapshot.masking.namesMasked = $true
		$path = Save-ColTestArchive -Snapshot $snapshot -Prompts @() -Config $script:Config
		$archive = & $script:Module { param($p) Read-IaSnapshotArchive -Path $p } $path
		$archive.maskingMap | Should -BeNullOrEmpty
		@($archive.prompts).Count | Should -Be 0
	}

	It 'відсутній файл, не ZIP або ZIP без snapshot.json — IaArchiveInvalid' {
		$missing = Join-Path $script:Root 'none.zip'
		{ & $script:Module { param($p) Read-IaSnapshotArchive -Path $p } $missing } | Should -Throw -ErrorId 'IaArchiveInvalid'
		$null = New-Item -ItemType Directory -Path $script:Root -Force
		$notZip = Join-Path $script:Root 'bad.zip'
		Set-Content -LiteralPath $notZip -Value 'not a zip'
		{ & $script:Module { param($p) Read-IaSnapshotArchive -Path $p } $notZip } | Should -Throw -ErrorId 'IaArchiveInvalid'
		$folder = Join-Path $script:Root 'content'
		$null = New-Item -ItemType Directory -Path $folder -Force
		Set-Content -LiteralPath (Join-Path $folder 'manifest.json') -Value '{"schemaVersion":"1.0"}'
		$noSnapshot = Join-Path $script:Root 'nosnapshot.zip'
		Compress-Archive -Path (Join-Path $folder '*') -DestinationPath $noSnapshot
		{ & $script:Module { param($p) Read-IaSnapshotArchive -Path $p } $noSnapshot } | Should -Throw -ErrorId 'IaArchiveInvalid'
	}
}

Describe 'Remove-IaExpiredArchives' {
	BeforeEach {
		$script:Root = Join-Path (Get-PSDrive TestDrive).Root ([guid]::NewGuid().ToString('N'))
		$script:Config = Get-IaTestConfig -Root $script:Root
		$script:Config.archive.retentionDays = 30
	}

	It 'видаляє архіви й мапи, старші за retentionDays; свіжі й сторонні файли лишаються' {
		$directory = $script:Config.archive.path
		$null = New-Item -ItemType Directory -Path $directory -Force
		$old = Join-Path $directory '20260101_000000_SQL01_aaaaaaaa.zip'
		$oldMap = Join-Path $directory '20260101_000000_SQL01_aaaaaaaa.map.json'
		$fresh = Join-Path $directory '20261110_000000_SQL01_bbbbbbbb.zip'
		$freshMap = Join-Path $directory '20261110_000000_SQL01_bbbbbbbb.map.json'
		$foreign = Join-Path $directory 'notes.zip'
		foreach ($file in @($old, $oldMap, $fresh, $freshMap, $foreign)) {
			Set-Content -LiteralPath $file -Value 'x'
		}
		foreach ($file in @($old, $foreign)) {
			(Get-Item -LiteralPath $file).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-40)
		}
		(Get-Item -LiteralPath $oldMap).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-1)
		$removed = & $script:Module { param($c) Remove-IaExpiredArchives -Config $c } $script:Config
		@($removed | ForEach-Object { Split-Path -Leaf $_ } | Sort-Object) | Should -Be @('20260101_000000_SQL01_aaaaaaaa.map.json', '20260101_000000_SQL01_aaaaaaaa.zip')
		$old | Should -Not -Exist
		$oldMap | Should -Not -Exist
		$fresh | Should -Exist
		$freshMap | Should -Exist
		$foreign | Should -Exist
	}

	It 'немає каталогу — порожній результат; WhatIf нічого не видаляє' {
		@(& $script:Module { param($c) Remove-IaExpiredArchives -Config $c } $script:Config).Count | Should -Be 0
		$directory = $script:Config.archive.path
		$null = New-Item -ItemType Directory -Path $directory -Force
		$old = Join-Path $directory '20260101_000000_SQL01_cccccccc.zip'
		Set-Content -LiteralPath $old -Value 'x'
		(Get-Item -LiteralPath $old).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-40)
		$null = & $script:Module { param($c) Remove-IaExpiredArchives -Config $c -WhatIf } $script:Config 6>$null
		$old | Should -Exist
	}
}
