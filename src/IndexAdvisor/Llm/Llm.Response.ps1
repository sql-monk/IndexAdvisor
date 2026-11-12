# Толерантний розбір відповіді моделі за contracts/llm-response.schema.json (CONTRACTS.md 3.4).
# Не кидає винятків: невалідні частини відкидаються з описом у parseErrors.

$script:IaLlmRiskLevels = @('Low', 'Medium', 'High')
$script:IaLlmTargetActionsRequiringIndex = @('DropIndex', 'AlterIndex')
$script:IaLlmPartitionActions = @('PartitionTable', 'AlterPartitioning')

function Get-IaLlmJsonCandidates {
	<# Внутрішня: кандидати на JSON у тексті: увесь текст, ```json-блоки, збалансований об'єкт від першої '{'. #>
	param([AllowEmptyString()][string]$Text)
	$candidates = [System.Collections.Generic.List[string]]::new()
	$trimmed = $Text.Trim()
	$candidates.Add($trimmed)
	foreach ($match in [regex]::Matches($Text, '(?s)```[ \t]*(?:json|JSON|Json)?[ \t]*\r?\n?(.*?)```')) {
		$candidates.Add($match.Groups[1].Value.Trim())
	}
	$start = $Text.IndexOf('{')
	if ($start -ge 0) {
		$depth = 0
		$inString = $false
		$escaped = $false
		for ($i = $start; $i -lt $Text.Length; $i++) {
			$ch = $Text[$i]
			if ($inString) {
				if ($escaped) { $escaped = $false }
				elseif ($ch -eq '\') { $escaped = $true }
				elseif ($ch -eq '"') { $inString = $false }
				continue
			}
			if ($ch -eq '"') { $inString = $true }
			elseif ($ch -eq '{') { $depth++ }
			elseif ($ch -eq '}') {
				$depth--
				if ($depth -eq 0) {
					$candidates.Add($Text.Substring($start, $i - $start + 1))
					break
				}
			}
		}
		$end = $Text.LastIndexOf('}')
		if ($end -gt $start) {
			$candidates.Add($Text.Substring($start, $end - $start + 1))
		}
	}
	return , $candidates.ToArray()
}

function ConvertFrom-IaLlmJsonText {
	<# Внутрішня: перший кандидат, що розбирається як JSON-об'єкт (або масив). Повертає @{ value; error }. #>
	param([AllowEmptyString()][string]$Text)
	$parameters = @{ AsHashtable = $true; Depth = 100; NoEnumerate = $true; ErrorAction = 'Stop' }
	if ((Get-Command -Name ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
		# Рядки на зразок дат лишаються рядками.
		$parameters['DateKind'] = 'String'
	}
	$lastError = 'текст не містить JSON-об''єкта'
	foreach ($candidate in (Get-IaLlmJsonCandidates -Text $Text)) {
		if ([string]::IsNullOrWhiteSpace($candidate) -or -not ($candidate.StartsWith('{') -or $candidate.StartsWith('['))) {
			continue
		}
		try {
			$value = ConvertFrom-Json -InputObject $candidate @parameters
			if ($value -is [System.Collections.IDictionary] -or (Test-IaLlmList -Value $value)) {
				return @{ value = $value; error = $null }
			}
		}
		catch {
			$lastError = $_.Exception.Message
		}
	}
	return @{ value = $null; error = $lastError }
}

function Resolve-IaLlmEnum {
	<# Внутрішня: значення переліку без урахування регістру -> канонічне написання; $null, якщо не входить. #>
	param([AllowNull()]$Value, [Parameter(Mandatory)][string[]]$Allowed)
	if ($Value -isnot [string]) {
		return $null
	}
	foreach ($item in $Allowed) {
		if ([string]::Equals($item, $Value.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
			return $item
		}
	}
	return $null
}

function ConvertTo-IaLlmStringList {
	<# Внутрішня: масив рядків (null і нерядкові елементи відкидаються; рядок -> масив з одного елемента). #>
	param([AllowNull()]$Value)
	return , @(@($Value) | Where-Object { $_ -is [string] -and $_ -ne '' })
}

function ConvertTo-IaLlmIntegerList {
	<# Внутрішня: масив цілих (рядки з цілими перетворюються; решта відкидається). #>
	param([AllowNull()]$Value)
	$items = [System.Collections.Generic.List[long]]::new()
	foreach ($item in @($Value)) {
		$number = 0L
		if ($item -is [long] -or $item -is [int]) {
			$items.Add([long]$item)
		}
		elseif ($item -is [double] -and [Math]::Floor($item) -eq $item) {
			$items.Add([long]$item)
		}
		elseif ($item -is [string] -and [long]::TryParse($item, [ref]$number)) {
			$items.Add($number)
		}
	}
	return , $items.ToArray()
}

function Test-IaLlmNonEmptyString {
	<# Внутрішня: непорожній рядок. #>
	param([AllowNull()]$Value)
	return ($Value -is [string]) -and -not [string]::IsNullOrWhiteSpace($Value)
}

function ConvertTo-IaLlmDraft {
	<# Внутрішня: перевірка й нормалізація однієї чернетки рекомендації; $null і запис у Errors, якщо вона невалідна. #>
	param(
		[AllowNull()]$Item,
		[Parameter(Mandatory)][int]$Index,
		[Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Errors
	)
	$prefix = "recommendations[$Index]"
	if ($Item -isnot [System.Collections.IDictionary]) {
		$Errors.Add("${prefix}: очікувався об'єкт; рекомендацію відкинуто.")
		return $null
	}
	$problems = [System.Collections.Generic.List[string]]::new()
	$action = Resolve-IaLlmEnum -Value (Get-IaLlmValue -InputObject $Item -Name 'action') -Allowed $script:IaActions
	if (-not $action) {
		$problems.Add("action: недопустиме значення (очікується $($script:IaActions -join '|'))")
	}
	$rawTarget = Get-IaLlmValue -InputObject $Item -Name 'target'
	$target = $null
	if ($rawTarget -isnot [System.Collections.IDictionary]) {
		$problems.Add('target: очікувався об''єкт')
	}
	else {
		$target = [ordered]@{}
		foreach ($name in @('server', 'database', 'schema', 'table')) {
			$value = Get-IaLlmValue -InputObject $rawTarget -Name $name
			if (-not (Test-IaLlmNonEmptyString -Value $value)) {
				$problems.Add("target.${name}: потрібен непорожній рядок")
			}
			$target[$name] = $(if ($value -is [string]) { $value.Trim() } else { $null })
		}
		$indexValue = Get-IaLlmValue -InputObject $rawTarget -Name 'index'
		$target['index'] = $(if (Test-IaLlmNonEmptyString -Value $indexValue) { $indexValue.Trim() } else { $null })
		if ($action -in $script:IaLlmTargetActionsRequiringIndex -and -not $target['index']) {
			$problems.Add("target.index: обов'язковий для $action")
		}
	}
	$texts = [ordered]@{}
	foreach ($name in @('title', 'rationale', 'executeScript', 'rollbackScript')) {
		$value = Get-IaLlmValue -InputObject $Item -Name $name
		if (-not (Test-IaLlmNonEmptyString -Value $value)) {
			$problems.Add("${name}: потрібен непорожній рядок")
		}
		$texts[$name] = [string]$value
	}
	$rawRisk = Get-IaLlmValue -InputObject $Item -Name 'risk'
	$risk = $null
	if ($rawRisk -isnot [System.Collections.IDictionary]) {
		$problems.Add('risk: очікувався об''єкт { level; description }')
	}
	else {
		$level = Resolve-IaLlmEnum -Value (Get-IaLlmValue -InputObject $rawRisk -Name 'level') -Allowed $script:IaLlmRiskLevels
		$description = Get-IaLlmValue -InputObject $rawRisk -Name 'description'
		if (-not $level) {
			$problems.Add('risk.level: очікується Low|Medium|High')
		}
		if ($description -isnot [string]) {
			$problems.Add('risk.description: потрібен рядок')
		}
		$risk = [ordered]@{ level = $level; description = [string]$description }
	}
	$partitioning = $null
	$rawPartitioning = Get-IaLlmValue -InputObject $Item -Name 'partitioning'
	if ($rawPartitioning -is [System.Collections.IDictionary]) {
		$partitioning = ConvertTo-IaLlmPartitioning -Value $rawPartitioning -Problems $problems
	}
	elseif ($null -ne $rawPartitioning) {
		$problems.Add('partitioning: очікувався об''єкт або null')
	}
	if ($action -in $script:IaLlmPartitionActions -and $null -eq $partitioning -and $null -eq $rawPartitioning) {
		$problems.Add("partitioning: обов'язковий для $action")
	}
	if ($problems.Count -gt 0) {
		$Errors.Add("${prefix}: $($problems -join '; '); рекомендацію відкинуто.")
		return $null
	}
	return [ordered]@{
		action = $action
		target = $target
		title = $texts['title']
		rationale = $texts['rationale']
		risk = $risk
		executeScript = $texts['executeScript']
		rollbackScript = $texts['rollbackScript']
		affectedQueryIds = ConvertTo-IaLlmIntegerList -Value (Get-IaLlmValue -InputObject $Item -Name 'affectedQueryIds')
		replacesIndexes = ConvertTo-IaLlmStringList -Value (Get-IaLlmValue -InputObject $Item -Name 'replacesIndexes')
		confidence = Resolve-IaLlmEnum -Value (Get-IaLlmValue -InputObject $Item -Name 'confidence') -Allowed $script:IaLlmRiskLevels
		partitioning = $partitioning
	}
}

function ConvertTo-IaLlmPartitioning {
	<# Внутрішня: перевірка й нормалізація об'єкта partitioning. #>
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Value,
		[Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Problems
	)
	foreach ($name in @('partitionColumn', 'functionScript', 'schemeScript', 'maintenanceBenefits')) {
		if (-not (Test-IaLlmNonEmptyString -Value (Get-IaLlmValue -InputObject $Value -Name $name))) {
			$Problems.Add("partitioning.${name}: потрібен непорожній рядок")
		}
	}
	$migrationPlan = Get-IaLlmValue -InputObject $Value -Name 'migrationPlan'
	if ($null -eq $migrationPlan) {
		$Problems.Add('partitioning.migrationPlan: потрібен масив кроків')
	}
	$rawImpact = Get-IaLlmValue -InputObject $Value -Name 'impact'
	if ($rawImpact -isnot [System.Collections.IDictionary]) {
		$Problems.Add('partitioning.impact: очікувався об''єкт')
		$rawImpact = @{}
	}
	$optionalString = {
		param($Source, $Name)
		$item = Get-IaLlmValue -InputObject $Source -Name $Name
		if ($item -is [string]) { $item } else { $null }
	}
	$impact = [ordered]@{
		clusteredIndexRebuild = [string](& $optionalString $rawImpact 'clusteredIndexRebuild')
		nonAlignedIndexes = ConvertTo-IaLlmStringList -Value (Get-IaLlmValue -InputObject $rawImpact -Name 'nonAlignedIndexes')
		primaryKeyAndUniqueChanges = ConvertTo-IaLlmStringList -Value (Get-IaLlmValue -InputObject $rawImpact -Name 'primaryKeyAndUniqueChanges')
		foreignKeys = ConvertTo-IaLlmStringList -Value (Get-IaLlmValue -InputObject $rawImpact -Name 'foreignKeys')
		replication = [string](& $optionalString $rawImpact 'replication')
		queriesWithoutPartitionFilter = ConvertTo-IaLlmIntegerList -Value (Get-IaLlmValue -InputObject $rawImpact -Name 'queriesWithoutPartitionFilter')
	}
	return [ordered]@{
		partitionColumn = [string](Get-IaLlmValue -InputObject $Value -Name 'partitionColumn')
		functionName = & $optionalString $Value 'functionName'
		schemeName = & $optionalString $Value 'schemeName'
		functionScript = [string](Get-IaLlmValue -InputObject $Value -Name 'functionScript')
		schemeScript = [string](Get-IaLlmValue -InputObject $Value -Name 'schemeScript')
		boundaries = ConvertTo-IaLlmStringList -Value (Get-IaLlmValue -InputObject $Value -Name 'boundaries')
		migrationPlan = ConvertTo-IaLlmStringList -Value $migrationPlan
		impact = $impact
		maintenanceBenefits = [string](Get-IaLlmValue -InputObject $Value -Name 'maintenanceBenefits')
		eliminationAssessment = & $optionalString $Value 'eliminationAssessment'
	}
}

function ConvertTo-IaLlmToolRequest {
	<# Внутрішня: перевірка й нормалізація одного дозапиту; $null і запис у Errors, якщо він невалідний. #>
	param(
		[AllowNull()]$Item,
		[Parameter(Mandatory)][int]$Index,
		[Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Errors
	)
	$prefix = "toolRequests[$Index]"
	if ($Item -isnot [System.Collections.IDictionary]) {
		$Errors.Add("${prefix}: очікувався об'єкт; дозапит відкинуто.")
		return $null
	}
	$tool = Get-IaLlmValue -InputObject $Item -Name 'tool'
	if (-not (Test-IaLlmNonEmptyString -Value $tool)) {
		$Errors.Add("${prefix}: tool — потрібна назва інструмента; дозапит відкинуто.")
		return $null
	}
	$arguments = Get-IaLlmValue -InputObject $Item -Name 'arguments'
	if ($null -eq $arguments) {
		$arguments = [ordered]@{}
	}
	if ($arguments -isnot [System.Collections.IDictionary]) {
		$Errors.Add("${prefix}: arguments — очікувався об'єкт; дозапит відкинуто.")
		return $null
	}
	$optionalCount = {
		param($Name)
		$value = Get-IaLlmValue -InputObject $Item -Name $Name
		$number = 0L
		if (($value -is [long] -or $value -is [int]) -and $value -ge 0) { return [long]$value }
		if ($value -is [string] -and [long]::TryParse($value, [ref]$number) -and $number -ge 0) { return $number }
		return $null
	}
	$server = Get-IaLlmValue -InputObject $Item -Name 'server'
	$database = Get-IaLlmValue -InputObject $Item -Name 'database'
	$reason = Get-IaLlmValue -InputObject $Item -Name 'reason'
	return [ordered]@{
		tool = $tool.Trim()
		server = $(if (Test-IaLlmNonEmptyString -Value $server) { $server.Trim() } else { $null })
		database = $(if (Test-IaLlmNonEmptyString -Value $database) { $database.Trim() } else { $null })
		arguments = ConvertTo-IaLlmPlainValue -Value $arguments
		fetch = & $optionalCount 'fetch'
		skip = & $optionalCount 'skip'
		reason = $(if ($reason -is [string]) { $reason } else { '' })
	}
}

function ConvertFrom-IaLlmResponse {
	<# Розбирає текст відповіді моделі (JSON, можливо в ```json-блоці) за contracts/llm-response.schema.json.
	   Повертає @{ recommendations = @(); toolRequests = @(); notes; parseErrors = @() }. Не кидає винятків. #>
	[CmdletBinding()]
	param([AllowEmptyString()][AllowNull()][string]$Text)
	$recommendations = [System.Collections.Generic.List[object]]::new()
	$toolRequests = [System.Collections.Generic.List[object]]::new()
	$errors = [System.Collections.Generic.List[string]]::new()
	$notes = $null
	try {
		if ([string]::IsNullOrWhiteSpace($Text)) {
			$errors.Add('Порожня відповідь моделі.')
		}
		else {
			$parsed = ConvertFrom-IaLlmJsonText -Text $Text
			$root = $parsed.value
			if ($null -eq $root) {
				$errors.Add("Відповідь моделі не містить коректного JSON-об'єкта: $($parsed.error)")
			}
			else {
				if (Test-IaLlmList -Value $root) {
					$errors.Add('Очікувався JSON-об''єкт { recommendations; toolRequests; notes }, отримано масив; його розібрано як recommendations.')
					$root = [ordered]@{ recommendations = $root; toolRequests = @() }
				}
				$rawRecommendations = Get-IaLlmValue -InputObject $root -Name 'recommendations'
				$rawToolRequests = Get-IaLlmValue -InputObject $root -Name 'toolRequests'
				if ($null -eq $rawRecommendations -and $null -eq $rawToolRequests) {
					$errors.Add('У відповіді немає ні recommendations, ні toolRequests.')
				}
				if ($null -ne $rawRecommendations) {
					if (-not (Test-IaLlmList -Value $rawRecommendations)) {
						$errors.Add('recommendations: очікувався масив.')
					}
					else {
						for ($i = 0; $i -lt $rawRecommendations.Count; $i++) {
							$draft = ConvertTo-IaLlmDraft -Item $rawRecommendations[$i] -Index $i -Errors $errors
							if ($null -ne $draft) {
								$recommendations.Add($draft)
							}
						}
					}
				}
				if ($null -ne $rawToolRequests) {
					if (-not (Test-IaLlmList -Value $rawToolRequests)) {
						$errors.Add('toolRequests: очікувався масив.')
					}
					else {
						for ($i = 0; $i -lt $rawToolRequests.Count; $i++) {
							$request = ConvertTo-IaLlmToolRequest -Item $rawToolRequests[$i] -Index $i -Errors $errors
							if ($null -ne $request) {
								$toolRequests.Add($request)
							}
						}
					}
				}
				$rawNotes = Get-IaLlmValue -InputObject $root -Name 'notes'
				if ($rawNotes -is [string]) {
					$notes = $rawNotes
				}
				elseif (Test-IaLlmList -Value $rawNotes) {
					$notes = (@($rawNotes | ForEach-Object { [string]$_ }) -join "`n")
				}
				elseif ($null -ne $rawNotes) {
					$notes = ConvertTo-IaLlmJson -Value $rawNotes
				}
			}
		}
	}
	catch {
		$errors.Add("Неочікувана помилка розбору відповіді моделі: $($_.Exception.Message)")
	}
	return [ordered]@{
		recommendations = $recommendations.ToArray()
		toolRequests = $toolRequests.ToArray()
		notes = $notes
		parseErrors = $errors.ToArray()
	}
}
