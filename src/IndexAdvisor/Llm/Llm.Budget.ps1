# Облік токенів, вартості й бюджету (ТЗ розділ 5; CONTRACTS.md 3.4).
# Облік — локальний JSON-файл llm.budgetLedgerPath: масив записів { utc; provider; model; inputTokens; outputTokens; costUsd; purpose }.

function Measure-IaTokens {
	<# Наближена оцінка кількості токенів тексту. #>
	[CmdletBinding()]
	[OutputType([int])]
	param([AllowEmptyString()][AllowNull()][string]$Text)
	if ([string]::IsNullOrEmpty($Text)) {
		return 0
	}
	# Консервативно: ~3,5 байта UTF-8 на токен (кирилиця займає 2 байти на символ, тож оцінюється щільніше).
	return [int][Math]::Ceiling([System.Text.Encoding]::UTF8.GetByteCount($Text) / 3.5)
}

function Get-IaLlmCost {
	<# Вартість у USD за цінами провайдера (inputPricePer1MTokensUsd, outputPricePer1MTokensUsd). #>
	[CmdletBinding()]
	[OutputType([decimal])]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$ProviderConfig,
		[long]$InputTokens = 0,
		[long]$OutputTokens = 0
	)
	$inputPrice = [decimal]((Get-IaLlmValue -InputObject $ProviderConfig -Name 'inputPricePer1MTokensUsd') ?? 0)
	$outputPrice = [decimal]((Get-IaLlmValue -InputObject $ProviderConfig -Name 'outputPricePer1MTokensUsd') ?? 0)
	$cost = ([decimal]$InputTokens * $inputPrice + [decimal]$OutputTokens * $outputPrice) / [decimal]1000000
	return [decimal]::Round($cost, 6)
}

function Get-IaLlmLedgerPath {
	<# Внутрішня: повний шлях до файлу обліку витрат. #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
	$path = [string](Get-IaLlmValue -InputObject (Get-IaLlmValue -InputObject $Config -Name 'llm') -Name 'budgetLedgerPath')
	if ([string]::IsNullOrWhiteSpace($path)) {
		$path = './state/llm-usage.json'
	}
	return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
}

function Read-IaLlmLedger {
	<# Внутрішня: записи обліку. Повертає @{ entries; isValid } (isValid = $false, якщо файл пошкоджено). #>
	param([Parameter(Mandatory)][string]$Path)
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		return @{ entries = @(); isValid = $true }
	}
	try {
		$text = Get-Content -LiteralPath $Path -Raw -Encoding utf8 -ErrorAction Stop
		if ([string]::IsNullOrWhiteSpace($text)) {
			return @{ entries = @(); isValid = $true }
		}
		$parsed = ConvertFrom-Json -InputObject $text -AsHashtable -Depth 10 -NoEnumerate -ErrorAction Stop
		if (-not (Test-IaLlmList -Value $parsed)) {
			return @{ entries = @(); isValid = $false }
		}
		return @{ entries = @($parsed | Where-Object { $_ -is [System.Collections.IDictionary] }); isValid = $true }
	}
	catch {
		return @{ entries = @(); isValid = $false }
	}
}

function Add-IaLlmLedgerEntry {
	<# Внутрішня: додає запис в облік витрат. Пошкоджений файл зберігається з суфіксом .corrupt, облік починається заново. #>
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Entry
	)
	$path = Get-IaLlmLedgerPath -Config $Config
	$directory = Split-Path -Path $path -Parent
	if ($directory -and -not (Test-Path -LiteralPath $directory)) {
		$null = New-Item -ItemType Directory -Path $directory -Force
	}
	$ledger = Read-IaLlmLedger -Path $path
	if (-not $ledger.isValid) {
		$backup = '{0}.{1}.corrupt' -f $path, [datetime]::UtcNow.ToString('yyyyMMddHHmmss')
		Move-Item -LiteralPath $path -Destination $backup -Force
		Write-Warning "IndexAdvisor: файл обліку витрат LLM пошкоджено; його збережено як '$backup', облік починається заново."
	}
	$entries = [System.Collections.Generic.List[object]]::new()
	foreach ($existing in $ledger.entries) {
		$entries.Add($existing)
	}
	$entries.Add($Entry)
	$json = ConvertTo-Json -InputObject $entries.ToArray() -Depth 10
	[System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Get-IaBudgetStatus {
	<# @{ provider; dailySpentUsd; monthlySpentUsd; dailyBudgetUsd; monthlyBudgetUsd; isExceeded } з llm.budgetLedgerPath. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$ProviderConfig,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	$providerName = [string](Get-IaLlmValue -InputObject $ProviderConfig -Name 'name')
	$dailyBudget = [decimal]((Get-IaLlmValue -InputObject $ProviderConfig -Name 'dailyBudgetUsd') ?? 0)
	$monthlyBudget = [decimal]((Get-IaLlmValue -InputObject $ProviderConfig -Name 'monthlyBudgetUsd') ?? 0)
	$ledger = Read-IaLlmLedger -Path (Get-IaLlmLedgerPath -Config $Config)
	$now = [datetime]::UtcNow
	$daily = [decimal]0
	$monthly = [decimal]0
	foreach ($entry in $ledger.entries) {
		if (-not [string]::Equals([string]$entry['provider'], $providerName, [System.StringComparison]::OrdinalIgnoreCase)) {
			continue
		}
		$utc = ConvertTo-IaLlmUtcDate -Value $entry['utc']
		if ($null -eq $utc) {
			continue
		}
		$cost = [decimal]0
		if ($null -ne $entry['costUsd']) {
			$cost = [decimal]$entry['costUsd']
		}
		if ($utc.Year -eq $now.Year -and $utc.Month -eq $now.Month) {
			$monthly += $cost
			if ($utc.Day -eq $now.Day) {
				$daily += $cost
			}
		}
	}
	$isExceeded = ($dailyBudget -gt 0 -and $daily -ge $dailyBudget) -or ($monthlyBudget -gt 0 -and $monthly -ge $monthlyBudget)
	if (-not $ledger.isValid -and ($dailyBudget -gt 0 -or $monthlyBudget -gt 0)) {
		# Бюджет неможливо перевірити — найбезпечніше вважати його вичерпаним.
		Write-Warning 'IndexAdvisor: файл обліку витрат LLM пошкоджено; бюджет неможливо перевірити, виклики заблоковано.'
		$isExceeded = $true
	}
	return [ordered]@{
		provider = $providerName
		dailySpentUsd = $daily
		monthlySpentUsd = $monthly
		dailyBudgetUsd = $dailyBudget
		monthlyBudgetUsd = $monthlyBudget
		isExceeded = [bool]$isExceeded
	}
}

function Assert-IaLlmBudget {
	<# Внутрішня: перевірка бюджету до виклику (з оцінкою вартості майбутнього запиту). Виняток 'IaBudgetExceeded'. #>
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$ProviderConfig,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config,
		[decimal]$EstimatedCostUsd = 0
	)
	$status = Get-IaBudgetStatus -ProviderConfig $ProviderConfig -Config $Config
	$exceeded = $status.isExceeded
	if (-not $exceeded -and $status.dailyBudgetUsd -gt 0 -and ($status.dailySpentUsd + $EstimatedCostUsd) -gt $status.dailyBudgetUsd) {
		$exceeded = $true
	}
	if (-not $exceeded -and $status.monthlyBudgetUsd -gt 0 -and ($status.monthlySpentUsd + $EstimatedCostUsd) -gt $status.monthlyBudgetUsd) {
		$exceeded = $true
	}
	if ($exceeded) {
		$message = "Бюджет провайдера '{0}' вичерпано: за день {1:0.######} з {2:0.######} USD, за місяць {3:0.######} з {4:0.######} USD (оцінка запиту {5:0.######} USD; 0 — без ліміту)." -f
			$status.provider, $status.dailySpentUsd, $status.dailyBudgetUsd, $status.monthlySpentUsd, $status.monthlyBudgetUsd, $EstimatedCostUsd
		throw (New-IaLlmErrorRecord -ErrorId 'IaBudgetExceeded' -Category LimitsExceeded -Message $message)
	}
}
