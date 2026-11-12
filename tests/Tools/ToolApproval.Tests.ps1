# Тести підтвердження дозапитів моделі (Request-IaToolApproval), потік Tools.
BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	. (Join-Path $PSScriptRoot 'Tools.TestHelpers.ps1')
	$script:module = Get-Module IndexAdvisor
	$script:tools = & $script:module { param($c) Import-IaToolDefinitions -Config $c } (Get-IaTestConfig)

	function New-TestRequest {
		return [ordered]@{
			tool = 'index_usage_stats'
			server = 'AG1'
			database = 'Sales'
			resolvedServer = 'SQL01'
			resolvedDatabase = 'Sales'
			arguments = [ordered]@{ SchemaName = 'dbo'; TableName = 'Orders'; MinUpdates = 0 }
			fetch = $null
			skip = $null
			reason = 'Потрібна статистика використання'
		}
	}

	function New-InteractiveConfig {
		$config = Get-IaTestConfig
		$config.run.nonInteractive = $false
		$config.llm.autoApproveToolRequests = $false
		return $config
	}

	function Invoke-TestApproval {
		param([System.Collections.IDictionary]$Request, [System.Collections.IDictionary]$Config)
		return (& $script:module { param($r, $t, $c) Request-IaToolApproval -ToolRequest $r -Tools $t -Config $c } $Request $script:tools $Config)
	}

	function Set-TestAnswers {
		param([string[]]$Answers)
		$script:answers = [System.Collections.Generic.Queue[string]]::new()
		foreach ($answer in $Answers) {
			$script:answers.Enqueue($answer)
		}
	}
}

Describe 'Request-IaToolApproval' {
	BeforeEach {
		Mock -ModuleName IndexAdvisor Write-IaLog {}
		Mock -ModuleName IndexAdvisor Write-Host {}
		Mock -ModuleName IndexAdvisor Read-IaToolUserInput {
			if ($script:answers.Count -eq 0) {
				throw 'Немає підготовлених відповідей'
			}
			$script:answers.Dequeue()
		}
	}

	It 'автопідтвердження: AutoApproved без діалогу' {
		$config = New-InteractiveConfig
		$config.llm.autoApproveToolRequests = $true
		$result = Invoke-TestApproval -Request (New-TestRequest) -Config $config
		$result.decision | Should -Be 'AutoApproved'
		$result.reason | Should -BeLike '*autoApproveToolRequests*'
		$result.toolRequest.arguments.TableName | Should -Be 'Orders'
		Should -Invoke -ModuleName IndexAdvisor Read-IaToolUserInput -Times 0 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Write-IaLog -Times 1 -Exactly -ParameterFilter { $Data.decision -eq 'AutoApproved' -and $Data.tool -eq 'index_usage_stats' }
	}

	It 'неінтерактивний режим без автопідтвердження: Rejected з поясненням' {
		$config = Get-IaTestConfig
		$config.llm.autoApproveToolRequests = $false
		$result = Invoke-TestApproval -Request (New-TestRequest) -Config $config
		$result.decision | Should -Be 'Rejected'
		$result.reason | Should -BeLike '*run.nonInteractive*autoApproveToolRequests*'
		Should -Invoke -ModuleName IndexAdvisor Read-IaToolUserInput -Times 0 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Write-IaLog -Times 1 -Exactly -ParameterFilter { $Data.decision -eq 'Rejected' }
	}

	It 'показує запит і підтверджує: Approved' {
		Set-TestAnswers -Answers @('П')
		$result = Invoke-TestApproval -Request (New-TestRequest) -Config (New-InteractiveConfig)
		$result.decision | Should -Be 'Approved'
		Should -Invoke -ModuleName IndexAdvisor Write-Host -ParameterFilter { "$Object" -like '*index_usage_stats*' }
		Should -Invoke -ModuleName IndexAdvisor Write-Host -ParameterFilter { "$Object" -like '*SQL01*AG1*' }
		Should -Invoke -ModuleName IndexAdvisor Write-Host -ParameterFilter { "$Object" -like '*@TableName = Orders*' }
		Should -Invoke -ModuleName IndexAdvisor Write-Host -ParameterFilter { "$Object" -like '*Потрібна статистика*' }
		Should -Invoke -ModuleName IndexAdvisor Write-Host -ParameterFilter { "$Object" -like '*sys.dm_db_index_usage_stats*' }
		Should -Invoke -ModuleName IndexAdvisor Write-IaLog -Times 1 -Exactly -ParameterFilter { $Data.decision -eq 'Approved' -and $Data.argument_TableName -eq 'Orders' }
	}

	It 'відхиляє з причиною: Rejected' {
		Set-TestAnswers -Answers @('в', 'Не зараз')
		$result = Invoke-TestApproval -Request (New-TestRequest) -Config (New-InteractiveConfig)
		$result.decision | Should -Be 'Rejected'
		$result.reason | Should -BeLike '*Не зараз*'
	}

	It 'змінює аргументи, fetch і skip з повторною перевіркою: Modified' {
		# Порядок: вибір, SchemaName, TableName, MinUpdates, Fetch, Skip.
		Set-TestAnswers -Answers @('з', '', 'Customers', '25', '100', '10')
		$result = Invoke-TestApproval -Request (New-TestRequest) -Config (New-InteractiveConfig)
		$result.decision | Should -Be 'Modified'
		$result.toolRequest.arguments.SchemaName | Should -Be 'dbo'
		$result.toolRequest.arguments.TableName | Should -Be 'Customers'
		$result.toolRequest.arguments.MinUpdates | Should -BeOfType [int]
		$result.toolRequest.arguments.MinUpdates | Should -Be 25
		$result.toolRequest.fetch | Should -Be 100
		$result.toolRequest.skip | Should -Be 10
		$result.toolRequest.resolvedServer | Should -Be 'SQL01'
	}

	It 'очищення необов''язкового аргументу повертає default' {
		Set-TestAnswers -Answers @('з', '', '', '-', '', '')
		$request = New-TestRequest
		$request.arguments.MinUpdates = 7
		$result = Invoke-TestApproval -Request $request -Config (New-InteractiveConfig)
		$result.decision | Should -Be 'Modified'
		$result.toolRequest.arguments.MinUpdates | Should -Be 0
	}

	It 'невалідна зміна не застосовується, далі можна відхилити' {
		Set-TestAnswers -Answers @('з', '', '', '-5', 'abc', '', 'в', '')
		$result = Invoke-TestApproval -Request (New-TestRequest) -Config (New-InteractiveConfig)
		$result.decision | Should -Be 'Rejected'
		$result.toolRequest.arguments.MinUpdates | Should -Be 0
		$result.toolRequest.fetch | Should -BeNullOrEmpty
		Should -Invoke -ModuleName IndexAdvisor Write-Host -ParameterFilter { "$Object" -like '*MinUpdates*мінімум*' -and "$Object" -like '*fetch*' }
	}

	It 'після трьох некоректних відповідей дозапит відхиляється' {
		Set-TestAnswers -Answers @('?', '', 'щось')
		$result = Invoke-TestApproval -Request (New-TestRequest) -Config (New-InteractiveConfig)
		$result.decision | Should -Be 'Rejected'
		$result.reason | Should -BeLike '*Немає коректної відповіді*'
		Should -Invoke -ModuleName IndexAdvisor Read-IaToolUserInput -Times 3 -Exactly
	}

	It 'невідомий інструмент відхиляється без діалогу' {
		$request = New-TestRequest
		$request.tool = 'drop_everything'
		$result = Invoke-TestApproval -Request $request -Config (New-InteractiveConfig)
		$result.decision | Should -Be 'Rejected'
		Should -Invoke -ModuleName IndexAdvisor Read-IaToolUserInput -Times 0 -Exactly
	}

	It 'вільний запит журналюється з рівнем Security' {
		$config = New-InteractiveConfig
		$config.unsafe.allowFreeQuery = $true
		$config.llm.autoApproveToolRequests = $true
		$tools = & $script:module { param($c) Import-IaToolDefinitions -Config $c } $config
		$request = [ordered]@{ tool = 'free_query'; server = 'SQL01'; database = 'Sales'; arguments = [ordered]@{ Sql = 'SELECT 1 AS x;' }; fetch = $null; skip = $null; reason = 'r' }
		$result = & $script:module { param($r, $t, $c) Request-IaToolApproval -ToolRequest $r -Tools $t -Config $c } $request $tools $config
		$result.decision | Should -Be 'AutoApproved'
		Should -Invoke -ModuleName IndexAdvisor Write-IaLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Security' }
	}
}
