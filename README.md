# AI Index Advisor (модуль IndexAdvisor)

Read-only система аналізу індексів SQL Server 2019+ з використанням LLM. Збирає метадані та статистику використання індексів (DMV, Query Store), виконує детермінований попередній аналіз (rules engine), передає стиснений контекст моделі (OpenAI, Anthropic, Cohere, Azure OpenAI або локальна OpenAI-сумісна) і формує рекомендації щодо створення, зміни та видалення індексів, а також щодо партиціонування.

**Програма ніколи не змінює цільові бази.** До цільових серверів надсилаються лише інструкції SELECT із системних каталогів, DMV і Query Store, кожна з яких перевіряється розбором ScriptDom. Результат — MD-файл, SQL-скрипти виконання й відкату та/або HTML-звіт; виконує їх DBA самостійно.

Вимоги — [tz.md](tz.md); контракти між компонентами — [CONTRACTS.md](CONTRACTS.md); JSON-схеми зібраних даних, рекомендації та відповіді моделі — [src/IndexAdvisor/contracts](src/IndexAdvisor/contracts); прийняті тлумачення неоднозначностей — [QUESTIONS.md](QUESTIONS.md).

## Встановлення

Потрібно PowerShell 7.2+ і модулі з PowerShell Gallery:

```powershell
Install-Module dbatools, powershell-yaml, Microsoft.PowerShell.SecretManagement -Scope CurrentUser
Install-Module Microsoft.PowerShell.SecretStore -Scope CurrentUser   # або інше сховище: Credential Manager, Azure Key Vault, HashiCorp Vault
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -SkipPublisherCheck   # лише для тестів
```

Модуль імпортується з теки репозиторію:

```powershell
Import-Module .\src\IndexAdvisor\IndexAdvisor.psd1
```

`Microsoft.SqlServer.TransactSql.ScriptDom` і `Microsoft.Data.SqlClient` беруться з `dbatools.library` (встановлюється разом із dbatools). dbatools завантажується ліниво — лише під час реальних підключень.

## Підготовка облікового запису на цільових серверах

Програма за замовчуванням підключається лише під штатним логіном `index-advisor` (ім'я задається в `security.standardLogin`). Логін створюється скриптом [sql/Setup-IndexAdvisorLogin.sql](sql/Setup-IndexAdvisorLogin.sql) з правами лише на метадані:

- серверна роль `srv_index_advisor`: `VIEW SERVER STATE`, `VIEW ANY DEFINITION`;
- у кожній цільовій базі — користувач і роль `db_index_advisor`: `VIEW DATABASE STATE`, `VIEW DEFINITION`;
- жодних прямих GRANT, жодного членства в `db_datareader`, `db_owner`, `sysadmin`, без SELECT на користувацькі таблиці.

Обгортка для кількох серверів генерує пароль (`CHECK_POLICY = ON`) і одразу зберігає його в SecretManagement:

```powershell
Register-SecretVault -Name IndexAdvisor -ModuleName Microsoft.PowerShell.SecretStore   # один раз
Install-IaServiceLogin -SqlInstance SQL01, SQL02 -Mode Install -Database Sales, DWH -SecretName IndexAdvisor-index-advisor -Vault IndexAdvisor
Install-IaServiceLogin -SqlInstance SQL01 -Mode AddDatabase -Database NewDb
Install-IaServiceLogin -SqlInstance SQL01 -Mode Verify      # фактичні права і попередження про зайві
Install-IaServiceLogin -SqlInstance SQL01 -Mode Remove      # повне видалення облікового запису
```

Скрипт можна виконати й напряму в режимі sqlcmd (змінні `Mode`, `LoginName`, `LoginType`, `LoginPassword`, `Databases`). Для Windows-облікового запису — `-WindowsLogin -LoginName 'DOMAIN\index-advisor'`; права надаються так само, через ролі.

## Репозиторій рекомендацій

Окрема база `IndexAdvisor` створюється скриптом [sql/Repository/IndexAdvisor.Repository.sql](sql/Repository/IndexAdvisor.Repository.sql) (схема `Advisor`, роль `db_index_advisor`). Вона зберігає лише результати аналізу: рекомендації, обґрунтування, скрипти виконання й відкату, модель, токени, вартість, період роботи сервера, результати перевірки та історію вердиктів для правил видалення. Сирі дані DMV і Query Store туди не потрапляють — вони лише в локальному ZIP-архіві запуску.

## Конфігурація YAML

Шаблон з усіма параметрами, значеннями за замовчуванням і коментарями:

```powershell
New-IaConfigTemplate -Path .\run.yaml
Test-IaConfig -Path .\run.yaml
```

Приклад мінімальної конфігурації:

```yaml
version: 1
servers:
  - AGL-SALES            # listener AG: програма сама визначить репліки й підключиться до кожної напряму
module: Indexes          # Indexes | Partitioning | Both
scope:
  databases:
    include: [Sales]
    exclude: []
  schemas:
    include: []
    exclude: [staging]
  tables:
    include: []
    exclude: [dbo.Log*]
analysisWindow:
  days: 30
connection:
  authentication: Sql
  login: index-advisor
  passwordRef: secret:IndexAdvisor/IndexAdvisor-index-advisor   # посилання, не пароль
collector:
  datasets:
    queryStore: true
    sizeAndFragmentation: false   # вимкнений набір позначається у звіті з попередженням
repository:
  enabled: true
  server: REPO01
  database: IndexAdvisor
llm:
  provider: openai
  maskNames: true
  providers:
    openai:
      type: OpenAI
      model: gpt-4.1
      apiKeyRef: secret:IndexAdvisor/openai-api-key
      dailyBudgetUsd: 20
      inputPricePer1MTokensUsd: 2
      outputPricePer1MTokensUsd: 8
    local:
      type: OpenAICompatible
      endpoint: http://localhost:11434/v1
      model: qwen2.5-coder:32b
      isLocal: true
```

Секрети (паролі, API-ключі) у YAML не зберігаються — лише посилання `secret:<Сховище>/<Секрет>`, `secret:<Секрет>` або `env:<ЗМІННА>`. Невідомі ключі, неправильні типи й відкриті секрети — помилка з номером рядка ще до запуску.

## Запуск

```powershell
# Повний цикл: збір, аналіз, рекомендації
Invoke-IndexAdvisor -Config .\run.yaml

# Параметри командного рядка мають пріоритет над YAML
Invoke-IndexAdvisor -Config .\run.yaml -Server SQL03 -Database Sales -Module Both -Provider local -Format Markdown, Sql, Html

# Разовий аналіз без запису в репозиторій
Invoke-IndexAdvisor -Config .\run.yaml -NoRepository

# Повторний аналіз зібраних даних іншою моделлю без нового збору
Invoke-IndexAdvisor -Config .\run.yaml -FromArchive .\archive\20261110_080000_AGL-SALES_5f0c1a2b.zip -Provider anthropic
```

Неінтерактивний запуск з кодом повернення (SQL Agent, Rundeck, cron, Планувальник завдань):

```powershell
pwsh -NoProfile -File .\bin\IndexAdvisor.ps1 -Config D:\IndexAdvisor\run.yaml -NonInteractive
```

Коди повернення: `0` успіх; `1` успіх з попередженнями (короткий період даних, частковий збір, рекомендації, що не пройшли перевірку); `2` помилка конфігурації; `3` відмова в підключенні (не штатний логін тощо); `4` помилка збору; `5` помилка LLM або перевищено бюджет; `6` помилка репозиторію; `9` неочікувана помилка.

У неінтерактивному режимі дозапити моделі відхиляються, якщо не ввімкнено автопідтвердження (`-AutoApprove` / `llm.autoApproveToolRequests`).

## Результати

У `output.path/<час>_<сервер>_<runId>/`:

- `recommendations.md` — рекомендації з обґрунтуванням, ризиком, періодом даних, результатами автоматичної перевірки та, для видалення, переліком виконаних і невиконаних умов;
- `sql/NNN_*.sql` і `sql/NNN_*_rollback.sql` — скрипти виконання й відкату (скрипт видалення, умови якого ще не виконано, записується із закоментованими інструкціями);
- `report.html` — самодостатній HTML-звіт, що поєднує все це;
- `result.json` — повний результат запуску.

Кожен звіт показує, за який період роботи сервера зібрано статистику (запуск інстансу, failover, період Query Store), які набори даних зібрано, чи застосовано маскування і які небезпечні режими були ввімкнені.

## Безпека

- Кожен запит — рівно одна інструкція SELECT (перевірка ScriptDom), джерела — лише `sys.*`, `INFORMATION_SCHEMA.*` і Query Store; до кожного батча додаються `READ UNCOMMITTED`, `LOCK_TIMEOUT`, `DEADLOCK_PRIORITY LOW`, а до запиту — `OPTION (MAXDOP 1)` і ліміт рядків.
- Модель не має доступу до серверів; її дозапити виконуються лише через декларативні інструменти після підтвердження користувача.
- У модель передаються лише метадані; літерали в текстах запитів очищуються завжди, імена об'єктів маскуються за `llm.maskNames`; режим `llm.localOnly` дозволяє лише локальну модель.
- Кожен виклик SQL записується в Markdown-журнал сесії (`logging.path`) з маскуванням секретів.
- Небезпечні режими (`-UnsafeDisableSelectCheck`, `-UnsafeDisableMaxdop`, `-UnsafeDisableTimeouts`, `-UnsafeAllowFreeQuery`, `-AllowNonStandardLogin`) вмикаються лише явно, з попередженням, записом у журнал і в кожну рекомендацію.
- Каталог архівів обмежено правами NTFS: архіви містять тексти запитів і структуру баз.

## Тести

```powershell
# Усі юніт-тести (моки SQL і LLM, без живих серверів і платних API)
Invoke-Pester -Path .\tests -ExcludeTagFilter Integration

# Тести одного модуля
Invoke-Pester -Path .\tests\Core
```

Тести з тегом `Integration` потребують живого SQL Server і запускаються лише вручну. Модель у них замокана, платних викликів немає. Параметри задаються змінними середовища (опис — на початку [tests/Integration/LiveRun.Integration.Tests.ps1](tests/Integration/LiveRun.Integration.Tests.ps1)):

```powershell
$env:IA_TEST_SQL_SERVER = 'SQL01'
$env:IA_TEST_SQL_DATABASE = 'Sales'
$env:IA_TEST_SQL_LOGIN = 'index-advisor'
$env:IA_TEST_SQL_PASSWORD = Read-Host 'Пароль index-advisor' -MaskInput
$env:IA_TEST_OUTPUT_PATH = '.\live-out'   # залишити звіти й журнали прогону
Invoke-Pester -Path .\tests\Integration, .\tests\Core\DbCommand.Integration.Tests.ps1 -TagFilter Integration -Output Detailed
```
