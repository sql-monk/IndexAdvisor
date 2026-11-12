# Шаблони промптів з версіями (CONTRACTS.md 3.4, 5.12). Файли: Llm/Prompts/<name>.v<N>.md з розділами "## System" і "## User".
# Плейсхолдери: {{payload}}, {{toolSchemas}}, {{responseSchema}}, {{maxToolRequests}}, {{namesMasked}}.

$script:IaLlmResponseSchemaCache = $null
$script:IaLlmPlaceholderRegex = [regex]::new('\{\{(\w+)\}\}')
$script:IaLlmCrossCheckSchema = [ordered]@{
	type = 'object'
	required = @('verdict', 'notes')
	additionalProperties = $false
	properties = [ordered]@{
		verdict = [ordered]@{ enum = @('Agree', 'Disagree', 'Uncertain') }
		notes = [ordered]@{ type = @('string', 'null') }
	}
}

function Get-IaLlmResponseSchema {
	<# Внутрішня: <модуль>/contracts/llm-response.schema.json як [ordered] (кешується). #>
	if ($null -eq $script:IaLlmResponseSchemaCache) {
		$path = Join-Path $script:IaModuleRoot 'contracts\llm-response.schema.json'
		if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
			throw [System.IO.FileNotFoundException]::new("Не знайдено схему відповіді моделі: $path")
		}
		$text = Get-Content -LiteralPath $path -Raw -Encoding utf8
		$script:IaLlmResponseSchemaCache = ConvertFrom-Json -InputObject $text -AsHashtable -Depth 100 -NoEnumerate
	}
	return (ConvertTo-IaLlmPlainValue -Value $script:IaLlmResponseSchemaCache)
}

function Get-IaPromptTemplate {
	<# Шаблон Llm/Prompts/<Name>.v<N>.md; Version = 0 — найновіша. Повертає @{ id; version; system; user; path }. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][ValidateSet('index-analysis', 'partition-analysis', 'cross-check')][string]$Name,
		[int]$Version = 0
	)
	$directory = Join-Path $script:IaModuleRoot 'Llm\Prompts'
	$pattern = '^' + [regex]::Escape($Name) + '\.v(\d+)\.md$'
	$available = @(Get-ChildItem -LiteralPath $directory -Filter "$Name.v*.md" -File -ErrorAction SilentlyContinue | ForEach-Object {
			if ($_.Name -match $pattern) {
				[pscustomobject]@{ version = [int]$Matches[1]; path = $_.FullName }
			}
		} | Sort-Object -Property version -Descending)
	$selected = if ($Version -gt 0) { $available | Where-Object { $_.version -eq $Version } | Select-Object -First 1 } else { $available | Select-Object -First 1 }
	if ($null -eq $selected) {
		$what = if ($Version -gt 0) { "версії $Version" } else { 'жодної версії' }
		throw [System.IO.FileNotFoundException]::new("Шаблон промпту '$Name': не знайдено $what у '$directory'.")
	}
	$text = (Get-Content -LiteralPath $selected.path -Raw -Encoding utf8) -replace "`r`n", "`n"
	$systemMatch = [regex]::Match($text, '(?m)^##[ \t]+System[ \t]*$')
	$userMatch = [regex]::Match($text, '(?m)^##[ \t]+User[ \t]*$')
	if (-not $systemMatch.Success -or -not $userMatch.Success -or $userMatch.Index -lt $systemMatch.Index) {
		throw [System.IO.InvalidDataException]::new("Шаблон промпту '$($selected.path)': потрібні розділи '## System' і '## User' (у цьому порядку).")
	}
	$systemStart = $systemMatch.Index + $systemMatch.Length
	return [ordered]@{
		id = $Name
		version = $selected.version
		system = $text.Substring($systemStart, $userMatch.Index - $systemStart).Trim()
		user = $text.Substring($userMatch.Index + $userMatch.Length).Trim()
		path = $selected.path
	}
}

function Format-IaLlmTemplate {
	<# Внутрішня: однопрохідна підстановка {{name}} (невідомі плейсхолдери лишаються; підставлений текст повторно не обробляється). #>
	param(
		[AllowEmptyString()][string]$Text,
		[Parameter(Mandatory)][hashtable]$Values
	)
	$builder = [System.Text.StringBuilder]::new()
	$position = 0
	foreach ($match in $script:IaLlmPlaceholderRegex.Matches($Text)) {
		$name = $match.Groups[1].Value
		if (-not $Values.ContainsKey($name)) {
			continue
		}
		$null = $builder.Append($Text, $position, $match.Index - $position).Append([string]$Values[$name])
		$position = $match.Index + $match.Length
	}
	$null = $builder.Append($Text, $position, $Text.Length - $position)
	return $builder.ToString()
}

function New-IaPrompt {
	<# Повний промпт: @{ templateId; templateVersion; messages = @(@{ role; content }); toolSchemas; responseSchema }.
	   Payload — уже маскований контекст (payload з New-IaLlmContext після ConvertTo-IaMaskedObject). #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][ValidateSet('index-analysis', 'partition-analysis', 'cross-check')][string]$TemplateName,
		[Parameter(Mandatory)][AllowNull()]$Payload,
		[object[]]$ToolSchemas = @(),
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	$template = Get-IaPromptTemplate -Name $TemplateName
	$responseSchema = if ($TemplateName -eq 'cross-check') { ConvertTo-IaLlmPlainValue -Value $script:IaLlmCrossCheckSchema } else { Get-IaLlmResponseSchema }
	$tools = @(@($ToolSchemas) | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-IaLlmPlainValue -Value $_ })

	$namesMasked = ConvertTo-IaLlmBool -Value (Get-IaLlmValue -InputObject (Get-IaLlmValue -InputObject $Config -Name 'llm') -Name 'maskNames')
	$masking = Get-IaLlmValue -InputObject $Payload -Name 'masking'
	if ($masking -is [System.Collections.IDictionary]) {
		$namesMasked = ConvertTo-IaLlmBool -Value (Get-IaLlmValue -InputObject $masking -Name 'namesMasked')
	}
	$maxToolRequests = Get-IaLlmValue -InputObject (Get-IaLlmValue -InputObject $Config -Name 'limits') -Name 'maxToolRequestsPerAnalysis'
	if ($null -eq $maxToolRequests) {
		$maxToolRequests = 10
	}
	$values = @{
		payload = ConvertTo-IaLlmJson -Value $Payload
		toolSchemas = (ConvertTo-Json -InputObject $tools -Depth 50 -Compress)
		responseSchema = ConvertTo-IaLlmJson -Value $responseSchema
		maxToolRequests = [string]$maxToolRequests
		namesMasked = $(if ($namesMasked) { 'true' } else { 'false' })
	}
	return [ordered]@{
		templateId = $template.id
		templateVersion = $template.version
		messages = @(
			[ordered]@{ role = 'system'; content = (Format-IaLlmTemplate -Text $template.system -Values $values) }
			[ordered]@{ role = 'user'; content = (Format-IaLlmTemplate -Text $template.user -Values $values) }
		)
		toolSchemas = $tools
		responseSchema = $responseSchema
	}
}
