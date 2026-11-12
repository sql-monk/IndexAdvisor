# Помічники тестів потоку Tools (dot-source у BeforeDiscovery і BeforeAll).

function New-SimpleTool {
	<# Текст мінімального валідного Markdown-інструмента із заданими назвою, параметрами й запитом. #>
	param(
		[string]$Name = 'simple_tool',
		[string]$Parameters = '- @TableName: string - Таблиця',
		[string]$Query = 'SELECT t.name FROM sys.tables AS t WHERE t.name = @TableName;'
	)
	return "# $Name`n`n## Description`nОпис.`n`n## Method`nQuery`n`n## Parameters`n$Parameters`n`n## Query`n``````sql`n$Query`n```````n"
}

function New-TestToolFile {
	<# Записує Markdown-інструмент у TestDrive:\<Folder>\<Name> і повертає шлях. #>
	param([string]$Name, [AllowEmptyString()][string]$Content, [string]$Folder = 'single')
	$directory = Join-Path $TestDrive $Folder
	if (-not (Test-Path -LiteralPath $directory)) {
		$null = New-Item -ItemType Directory -Path $directory
	}
	$path = Join-Path $directory $Name
	Set-Content -LiteralPath $path -Value $Content -Encoding utf8 -NoNewline
	return $path
}

function New-TestLlmResponse {
	<# LlmResponse (CONTRACTS.md 5.5) для моку Invoke-IaLlmChat. #>
	param(
		[string]$Text,
		[string]$Purpose = 'Analysis',
		[int]$InputTokens = 100,
		[int]$OutputTokens = 50,
		[double]$CostUsd = 0.01,
		[bool]$Success = $true,
		$ErrorValue = $null
	)
	return [ordered]@{
		llmCallId = [guid]::NewGuid().ToString()
		provider = 'test'
		model = 'test-model'
		purpose = $Purpose
		text = $Text
		inputTokens = $InputTokens
		outputTokens = $OutputTokens
		costUsd = $CostUsd
		durationMs = 10
		finishReason = 'stop'
		createdAtUtc = '2026-11-11T00:00:00.000Z'
		promptTemplateId = $null
		promptTemplateVersion = $null
		success = $Success
		error = $ErrorValue
	}
}

function New-TestModelText {
	<# JSON-текст відповіді моделі (llm-response) з рекомендаціями й дозапитами. #>
	param([object[]]$ToolRequests = @(), [object[]]$Recommendations = @(), [string]$Notes = $null)
	return (ConvertTo-Json -InputObject ([ordered]@{ recommendations = @($Recommendations); toolRequests = @($ToolRequests); notes = $Notes }) -Depth 20)
}

function New-TestEnvelope {
	<# Успішний конверт Invoke-IaSqlQuery з одним рядком. #>
	param([string]$Server, [string]$Database)
	return [ordered]@{
		success = $true
		requestId = [guid]::NewGuid().ToString()
		server = $Server
		database = $Database
		durationMs = 5
		rowCount = 1
		truncated = $false
		columns = @([ordered]@{ name = 'indexName'; type = 'nvarchar' })
		rows = @([ordered]@{ indexName = 'IX_Status' })
		messages = @()
		error = $null
	}
}
