# Юніт-тести повтору підключення при мережевому обриві до входу (Open-IaCoreSqlConnection, Test-IaCoreTransientConnectError).
# Справжній драйвер не потрібен: SqlException і підключення підмінено; Get-IaCoreSqlException розпізнає виняток за ім'ям типу.

class SqlException : System.Exception {
	[int]$Number
	[object[]]$Errors
	SqlException([string]$message, [int]$number) : base($message) {
		$this.Number = $number
		$this.Errors = @([pscustomobject]@{ Number = $number })
	}
}

BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	$script:Module = Get-Module IndexAdvisor

	function New-RetryTestFactory {
		<# Фабрика підроблених підключень: перші FailTimes викликів Open кидають SqlException з номером Number. #>
		param([int]$FailTimes, [int]$Number)
		$state = [pscustomobject]@{ OpenCalls = 0; Disposed = 0; FailTimes = $FailTimes; Number = $Number }
		$factory = {
			$connection = [pscustomobject]@{ State = $state }
			$connection | Add-Member -MemberType ScriptMethod -Name Open -Value {
				$this.State.OpenCalls++
				if ($this.State.OpenCalls -le $this.State.FailTimes) {
					throw [SqlException]::new('A connection was successfully established with the server, but then an error occurred during the pre-login handshake.', $this.State.Number)
				}
			}
			$connection | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.State.Disposed++ }
			$connection
		}.GetNewClosure()
		return @{ State = $state; Factory = $factory }
	}

	function Invoke-RetryTestOpen {
		param([scriptblock]$Factory, [System.Collections.Generic.List[string]]$Messages)
		& $script:Module {
			param($f, $m)
			Open-IaCoreSqlConnection -NewConnection $f -Messages $m -RetryDelaysMs @(0, 0)
		} $Factory $Messages
	}
}

Describe 'Open-IaCoreSqlConnection' {
	It 'відкриває з першої спроби без повідомлень' {
		$test = New-RetryTestFactory -FailTimes 0 -Number 10054
		$messages = [System.Collections.Generic.List[string]]::new()
		$connection = Invoke-RetryTestOpen -Factory $test.Factory -Messages $messages
		$connection | Should -Not -BeNullOrEmpty
		$test.State.OpenCalls | Should -Be 1
		$messages.Count | Should -Be 0
	}

	It 'повторює після обриву до входу (Msg <Number>) і записує кожен повтор' -ForEach @(
		@{ Number = 10054 }
		@{ Number = 10061 }
		@{ Number = 64 }
		@{ Number = -2 }
	) {
		$test = New-RetryTestFactory -FailTimes 2 -Number $Number
		$messages = [System.Collections.Generic.List[string]]::new()
		$connection = Invoke-RetryTestOpen -Factory $test.Factory -Messages $messages
		$connection | Should -Not -BeNullOrEmpty
		$test.State.OpenCalls | Should -Be 3
		$test.State.Disposed | Should -Be 2
		$messages.Count | Should -Be 2
		$messages[0] | Should -Match "Msg $Number.*повтор 1 з 2"
	}

	It 'після вичерпаних повторів кидає помилку останньої спроби' {
		$test = New-RetryTestFactory -FailTimes 5 -Number 10054
		$messages = [System.Collections.Generic.List[string]]::new()
		{ Invoke-RetryTestOpen -Factory $test.Factory -Messages $messages } | Should -Throw '*pre-login*'
		$test.State.OpenCalls | Should -Be 3
		$test.State.Disposed | Should -Be 3
	}

	It 'помилку входу (Msg 18456) не повторює' {
		$test = New-RetryTestFactory -FailTimes 5 -Number 18456
		$messages = [System.Collections.Generic.List[string]]::new()
		{ Invoke-RetryTestOpen -Factory $test.Factory -Messages $messages } | Should -Throw
		$test.State.OpenCalls | Should -Be 1
		$messages.Count | Should -Be 0
	}
}

Describe 'Test-IaCoreTransientConnectError' {
	It 'розпізнає номер у SqlException.Errors і відкидає інші винятки' {
		$inner = [SqlException]::new('wrapped', 4060)
		$inner.Errors = @([pscustomobject]@{ Number = 4060 }, [pscustomobject]@{ Number = 10054 })
		$wrapped = [System.Management.Automation.MethodInvocationException]::new('Exception calling "Open"', $inner)
		$result = & $script:Module {
			param($w, $plain)
			@((Test-IaCoreTransientConnectError -Exception $w), (Test-IaCoreTransientConnectError -Exception $plain), (Test-IaCoreTransientConnectError -Exception $null))
		} $wrapped ([System.InvalidOperationException]::new('інша помилка'))
		$result | Should -Be @($true, $false, $false)
	}
}
