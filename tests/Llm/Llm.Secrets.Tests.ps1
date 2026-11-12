BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	. (Join-Path $PSScriptRoot 'LlmTestHelpers.ps1')
}

Describe 'Test-IaSecretReference' {
	It 'приймає <Reference>' -TestCases @(
		@{ Reference = 'env:IA_KEY' }
		@{ Reference = 'ENV:Ia_Key_2' }
		@{ Reference = 'secret:IndexAdvisor-openai' }
		@{ Reference = 'secret:MyVault/IndexAdvisor-openai' }
	) {
		InModuleScope IndexAdvisor -Parameters @{ Reference = $Reference } { param($Reference) Test-IaSecretReference -Reference $Reference } | Should -BeTrue
	}

	It 'відхиляє <Reference>' -TestCases @(
		@{ Reference = 'sk-proj-0123456789abcdef' }
		@{ Reference = '' }
		@{ Reference = $null }
		@{ Reference = 'secret:' }
		@{ Reference = 'env:' }
		@{ Reference = 'env:1BAD' }
		@{ Reference = 'secret:a/b/c' }
		@{ Reference = ' secret:Name' }
		@{ Reference = 'vault:Name' }
	) {
		InModuleScope IndexAdvisor -Parameters @{ Reference = $Reference } { param($Reference) Test-IaSecretReference -Reference $Reference } | Should -BeFalse
	}
}

Describe 'Get-IaSecret' {
	BeforeEach {
		$env:IA_LLM_TEST_SECRET = 'env-secret-value'
		Remove-Item Env:\IA_LLM_TEST_MISSING -ErrorAction SilentlyContinue
	}
	AfterEach {
		Remove-Item Env:\IA_LLM_TEST_SECRET -ErrorAction SilentlyContinue
	}

	It 'env: повертає SecureString, з -AsPlainText — рядок' {
		$result = InModuleScope IndexAdvisor {
			@{ secure = Get-IaSecret -Reference 'env:IA_LLM_TEST_SECRET'; plain = Get-IaSecret -Reference 'env:IA_LLM_TEST_SECRET' -AsPlainText }
		}
		$result.secure | Should -BeOfType [securestring]
		[System.Net.NetworkCredential]::new('', $result.secure).Password | Should -Be 'env-secret-value'
		$result.plain | Should -Be 'env-secret-value'
	}

	It 'env: без змінної кидає IaSecretNotFound' {
		{ InModuleScope IndexAdvisor { Get-IaSecret -Reference 'env:IA_LLM_TEST_MISSING' } } | Should -Throw -ErrorId 'IaSecretNotFound*'
	}

	It 'secret:Name читає з SecretManagement без сховища' {
		Mock -ModuleName IndexAdvisor Get-Secret { ConvertTo-SecureString -String 'vault-value' -AsPlainText -Force }
		$plain = InModuleScope IndexAdvisor { Get-IaSecret -Reference 'secret:IndexAdvisor-openai' -AsPlainText }
		$plain | Should -Be 'vault-value'
		Should -Invoke -ModuleName IndexAdvisor Get-Secret -Times 1 -Exactly -ParameterFilter { $Name -eq 'IndexAdvisor-openai' -and -not $Vault }
	}

	It 'secret:Vault/Name передає сховище' {
		Mock -ModuleName IndexAdvisor Get-Secret { ConvertTo-SecureString -String 'kv-value' -AsPlainText -Force }
		$secure = InModuleScope IndexAdvisor { Get-IaSecret -Reference 'secret:CorpKeyVault/IndexAdvisor-openai' }
		$secure | Should -BeOfType [securestring]
		Should -Invoke -ModuleName IndexAdvisor Get-Secret -Times 1 -Exactly -ParameterFilter { $Name -eq 'IndexAdvisor-openai' -and $Vault -eq 'CorpKeyVault' }
	}

	It 'приймає PSCredential і рядок зі сховища' {
		Mock -ModuleName IndexAdvisor Get-Secret -ParameterFilter { $Name -eq 'cred' } { [pscredential]::new('user', (ConvertTo-SecureString -String 'cred-pass' -AsPlainText -Force)) }
		Mock -ModuleName IndexAdvisor Get-Secret -ParameterFilter { $Name -eq 'text' } { 'text-value' }
		InModuleScope IndexAdvisor { Get-IaSecret -Reference 'secret:cred' -AsPlainText } | Should -Be 'cred-pass'
		InModuleScope IndexAdvisor { Get-IaSecret -Reference 'secret:text' -AsPlainText } | Should -Be 'text-value'
	}

	It 'відсутній секрет — IaSecretNotFound без подробиць сховища' {
		Mock -ModuleName IndexAdvisor Get-Secret { throw 'vault-internal-detail: secret not found' }
		$caught = $null
		try {
			InModuleScope IndexAdvisor { Get-IaSecret -Reference 'secret:Missing' }
		}
		catch {
			$caught = $_
		}
		$caught.FullyQualifiedErrorId | Should -BeLike 'IaSecretNotFound*'
		$caught.Exception.Message | Should -Match "Missing"
		$caught.Exception.Message | Should -Not -Match 'vault-internal-detail'
	}

	It 'неправильний формат — IaSecretNotFound, значення не потрапляє у виняток' {
		$caught = $null
		try {
			InModuleScope IndexAdvisor { Get-IaSecret -Reference 'sk-live-TOPSECRET-0123456789' }
		}
		catch {
			$caught = $_
		}
		$caught.FullyQualifiedErrorId | Should -BeLike 'IaSecretNotFound*'
		$caught.Exception.Message | Should -Not -Match 'TOPSECRET'
	}

	It 'ключ провайдера з secret: доходить до заголовка запиту' {
		$config = New-IaLlmTestConfig
		$config.llm.providers.openai.apiKeyRef = 'secret:IndexAdvisor-openai'
		Mock -ModuleName IndexAdvisor Get-Secret { ConvertTo-SecureString -String 'sk-from-vault-123456' -AsPlainText -Force }
		Mock -ModuleName IndexAdvisor Invoke-RestMethod { New-IaLlmTestOpenAiResponse }
		Mock -ModuleName IndexAdvisor Write-IaLog { }
		$null = InModuleScope IndexAdvisor -Parameters @{ Config = $config } {
			param($Config)
			Invoke-IaLlmChat -ProviderConfig (Get-IaLlmProviderConfig -Name 'openai' -Config $Config) -Messages @(@{ role = 'user'; content = 'JSON' }) -Config $Config
		}
		Should -Invoke -ModuleName IndexAdvisor Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Headers['Authorization'] -eq 'Bearer sk-from-vault-123456' }
		Should -Invoke -ModuleName IndexAdvisor Write-IaLog -Times 0 -ParameterFilter { ($Message + ($Data | ConvertTo-Json -Compress)) -match 'sk-from-vault' }
	}
}
