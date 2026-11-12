# Cross-check критичних рекомендацій другою моделлю (ТЗ розділ 5; CONTRACTS.md 3.4; QUESTIONS.md, оркестратор, п. 17).
# Критична рекомендація: action = DropIndex або risk.level = High.

$script:IaLlmVerdicts = @('Agree', 'Disagree', 'Uncertain')

function Test-IaLlmCriticalRecommendation {
	<# Внутрішня: $true для DropIndex і рекомендацій з risk.level = High. #>
	param([AllowNull()]$Recommendation)
	if ($Recommendation -isnot [System.Collections.IDictionary]) {
		return $false
	}
	if ([string](Get-IaLlmValue -InputObject $Recommendation -Name 'action') -eq 'DropIndex') {
		return $true
	}
	$risk = Get-IaLlmValue -InputObject $Recommendation -Name 'risk'
	return [string](Get-IaLlmValue -InputObject $risk -Name 'level') -eq 'High'
}

function ConvertFrom-IaLlmCrossCheckText {
	<# Внутрішня: @{ verdict; notes; error } з відповіді моделі cross-check. #>
	param([AllowNull()][AllowEmptyString()][string]$Text)
	if ([string]::IsNullOrWhiteSpace($Text)) {
		return @{ verdict = 'Uncertain'; notes = $null; error = 'порожня відповідь' }
	}
	$parsed = ConvertFrom-IaLlmJsonText -Text $Text
	if ($parsed.value -isnot [System.Collections.IDictionary]) {
		return @{ verdict = 'Uncertain'; notes = $null; error = "немає JSON-об'єкта ($($parsed.error))" }
	}
	$verdict = Resolve-IaLlmEnum -Value (Get-IaLlmValue -InputObject $parsed.value -Name 'verdict') -Allowed $script:IaLlmVerdicts
	$notes = Get-IaLlmValue -InputObject $parsed.value -Name 'notes'
	$notesText = if ($notes -is [string]) { $notes } elseif ($null -ne $notes) { ConvertTo-IaLlmJson -Value $notes } else { $null }
	if (-not $verdict) {
		return @{ verdict = 'Uncertain'; notes = $notesText; error = 'verdict має бути Agree|Disagree|Uncertain' }
	}
	return @{ verdict = $verdict; notes = $notesText; error = $null }
}

function Invoke-IaCrossCheck {
	<# Cross-check критичних рекомендацій (action = DropIndex або risk.level = High) другою моделлю llm.crossCheckProvider.
	   Заповнює recommendation.crossCheck = @{ provider; model; verdict = Agree|Disagree|Uncertain; notes; llmCallId }.
	   Повертає @{ recommendations; calls = @(LlmResponse) }. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Recommendations,
		[Parameter(Mandatory)][AllowNull()]$Payload,
		[System.Collections.IDictionary]$MaskingMap,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	$calls = [System.Collections.Generic.List[object]]::new()
	$llm = Get-IaLlmValue -InputObject $Config -Name 'llm'
	$providerName = [string](Get-IaLlmValue -InputObject $llm -Name 'crossCheckProvider')
	if ([string]::IsNullOrWhiteSpace($providerName)) {
		return [ordered]@{ recommendations = $Recommendations; calls = @() }
	}
	$critical = @($Recommendations | Where-Object { Test-IaLlmCriticalRecommendation -Recommendation $_ })
	if ($critical.Count -eq 0) {
		return [ordered]@{ recommendations = $Recommendations; calls = @() }
	}
	$maskNames = ConvertTo-IaLlmBool -Value (Get-IaLlmValue -InputObject $llm -Name 'maskNames')
	if ($maskNames -and $null -eq $MaskingMap) {
		# Без мапи справжні імена потрапили б у зовнішній сервіс, а псевдоніми не збіглися б з контекстом.
		$PSCmdlet.ThrowTerminatingError((New-IaLlmErrorRecord -ErrorId 'IaConfigInvalid' -Category InvalidArgument -Message (
			'llm.maskNames увімкнено, але мапу маскування не передано: cross-check без маскування імен заборонено.')))
	}
	$providerConfig = Get-IaLlmProviderConfig -Name $providerName -Config $Config -IgnoreModelOverride
	Assert-IaProviderAllowed -ProviderConfig $providerConfig -Config $Config
	$map = if ($null -ne $MaskingMap) { $MaskingMap } else { New-IaMaskingMap }
	$contextMasking = Get-IaLlmValue -InputObject $Payload -Name 'masking'
	$budgetExceeded = $false

	foreach ($recommendation in $critical) {
		$verdict = 'Uncertain'
		$notes = $null
		$llmCallId = $null
		if ($budgetExceeded) {
			$notes = 'Cross-check не виконано: бюджет провайдера cross-check вичерпано.'
		}
		else {
			$target = Get-IaLlmValue -InputObject $recommendation -Name 'target'
			$impact = Get-IaLlmValue -InputObject $recommendation -Name 'impact'
			$affected = Get-IaLlmValue -InputObject $recommendation -Name 'affectedQueryIds'
			if ($null -eq $affected) {
				$affected = Get-IaLlmValue -InputObject $impact -Name 'affectedQueryIds'
			}
			$subject = [ordered]@{
				action = Get-IaLlmValue -InputObject $recommendation -Name 'action'
				target = [ordered]@{
					server = Get-IaLlmValue -InputObject $target -Name 'server'
					database = Get-IaLlmValue -InputObject $target -Name 'database'
					schema = Get-IaLlmValue -InputObject $target -Name 'schema'
					table = Get-IaLlmValue -InputObject $target -Name 'table'
					index = Get-IaLlmValue -InputObject $target -Name 'index'
				}
				title = Get-IaLlmValue -InputObject $recommendation -Name 'title'
				rationale = Get-IaLlmValue -InputObject $recommendation -Name 'rationale'
				risk = Get-IaLlmValue -InputObject $recommendation -Name 'risk'
				executeScript = Get-IaLlmValue -InputObject $recommendation -Name 'executeScript'
				rollbackScript = Get-IaLlmValue -InputObject $recommendation -Name 'rollbackScript'
				affectedQueryIds = @($affected | Where-Object { $null -ne $_ })
				replacesIndexes = @((Get-IaLlmValue -InputObject $recommendation -Name 'replacesIndexes') | Where-Object { $null -ne $_ })
				partitioning = Get-IaLlmValue -InputObject $recommendation -Name 'partitioning'
			}
			$maskedSubject = ConvertTo-IaMaskedObject -InputObject $subject -Map $map -Config $Config
			$crossPayload = [ordered]@{
				masking = ConvertTo-IaLlmPlainValue -Value $contextMasking
				recommendation = $maskedSubject
				context = $Payload
			}
			$prompt = New-IaPrompt -TemplateName 'cross-check' -Payload $crossPayload -Config $Config
			$response = $null
			try {
				$response = Invoke-IaLlmChat -ProviderConfig $providerConfig -Messages $prompt.messages -JsonResponse -Purpose CrossCheck -Config $Config
			}
			catch {
				if ($_.FullyQualifiedErrorId -like 'IaBudgetExceeded*') {
					$budgetExceeded = $true
					$notes = 'Cross-check не виконано: бюджет провайдера cross-check вичерпано.'
				}
				else {
					throw
				}
			}
			if ($null -ne $response) {
				$response['promptTemplateId'] = $prompt.templateId
				$response['promptTemplateVersion'] = $prompt.templateVersion
				$calls.Add($response)
				$llmCallId = $response['llmCallId']
				if ($response['success']) {
					$parsed = ConvertFrom-IaLlmCrossCheckText -Text $response['text']
					$verdict = $parsed.verdict
					$notes = $parsed.notes
					if ($parsed.error) {
						$notes = ('Не вдалося розібрати відповідь cross-check ({0}). {1}' -f $parsed.error, $notes).Trim()
					}
					if ($null -ne $MaskingMap -and $notes) {
						$notes = ConvertFrom-IaMaskedObject -InputObject $notes -Map $MaskingMap
					}
				}
				else {
					$notes = "Помилка виклику cross-check: $($response['error'])"
				}
			}
		}
		$recommendation['crossCheck'] = [ordered]@{
			provider = $providerConfig['name']
			model = $providerConfig['model']
			verdict = $verdict
			notes = $notes
			llmCallId = $llmCallId
		}
	}
	return [ordered]@{ recommendations = $Recommendations; calls = $calls.ToArray() }
}
