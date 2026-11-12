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
    anthropic:
      type: Anthropic
      model: claude-opus-5-5
      apiKeyRef: secret:IndexAdvisor/anthropic-api-key
      maxTokensPerRequest: 32000      # мислення моделі входить у цей ліміт
      maxContextTokens: 150000
      inputPricePer1MTokensUsd: 4
      outputPricePer1MTokensUsd: 20
      cacheReadPricePer1MTokensUsd: 0.2
    local:
      type: OpenAICompatible
      endpoint: http://localhost:11434/v1
      model: qwen2.5-coder:32b
      isLocal: true
```

У моделей з мисленням (Claude Opus 5.5, o-серія OpenAI) мислення входить у `maxTokensPerRequest`, тож задавайте 32000 або більше. Інакше відповідь обріжеться, і програма повідомить про це окремою помилкою. `maxContextTokens` обмежує контекст, який програма передає моделі; розмір оцінюється з розрахунку 1,8 байта на токен.

Для Anthropic за замовчуванням увімкнене кешування промптів (`promptCaching`): системний промпт і діалог кешуються, тож дозапити моделі читають великий контекст з кешу. У Claude Opus 5.5 це $0,20 за 1 млн токенів замість $4. Перший виклик платить за запис у кеш — 1,25 ціни входу. Записані й прочитані з кешу токени показуються у звіті.

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

## Графічний інтерфейс (Windows, .NET)

`src/IndexAdvisor.Gui` — WPF-застосунок на .NET 10 поверх того самого модуля: нічого з логіки аналізу не дублює, а викликає `Invoke-IndexAdvisor`, `Test-IaConfig`, `New-IaConfigTemplate`, `New-IaIndexMaintenance` і `Install-IaServiceLogin` у вбудованому PowerShell 7.6 (Microsoft.PowerShell.SDK). Окремо встановлений `pwsh` не потрібен; модулі з розділу «Встановлення» — потрібні. Тема — світла, темна або як у Windows (перемикається без перезапуску).

```powershell
dotnet run --project .\src\IndexAdvisor.Gui                     # з репозиторію (потрібен .NET 10 SDK)
dotnet publish .\src\IndexAdvisor.Gui -c Release -o D:\IndexAdvisor.Gui   # тека для DBA; запуск — IndexAdvisor.Gui.exe
.\IndexAdvisor.Gui.exe D:\IndexAdvisor\run.yaml                   # відкрити конфігурацію; тека або result.json — одразу «Результати»
```

- **Запуск.** Файл YAML перевіряється автоматично, а поля форми показують значення з конфігурації як підказки; заповнене поле перевизначає YAML так само, як параметр CLI. Перемикачі тристанні: «як у конфігурації», `-Switch`, `-Switch:$false`. Небезпечні режими — окремо й з підтвердженням. Внизу форми — готовий командний рядок для сесії PowerShell і для SQL Agent (CmdExec) чи Планувальника завдань (`pwsh -File bin\IndexAdvisor.ps1 ... -NonInteractive`).
- **Журнал** показує вивід модуля (`Write-Host`, попередження, помилки, `-Verbose`) під час виконання; «Зупинити» перериває конвеєр.
- **Дозапити моделі.** `Read-Host` модуля відкриває діалог: опис дозапиту (інструмент, сервер, база, аргументи, текст запиту) і кнопки «Підтвердити / Змінити / Відхилити» (або клавіші П/З/В). Так само в діалогах — пароль SecretStore і облікові дані. Без `-NonInteractive` і без автопідтвердження запуск чекає на рішення користувача; кнопка на панелі завдань блимає.
- **Конфігурація.** Форма всіх налаштувань YAML, побудована зі схеми модуля (`Shared/ConfigSchema.psd1`): розділи, пошук, описи, значення за замовчуванням, перевірка типів і меж, посилання на секрети лише як `secret:`/`env:`, провайдери LLM і перевизначення періоду спостереження як картки. Ключ записується у файл, лише якщо його задано (смуга зліва); «Скинути» повертає значення за замовчуванням. Поруч — текст YAML з нумерацією рядків і підсвіткою; форма й текст синхронізуються, перевірка (`Test-IaConfig`) переходить до рядка помилки. Форма записує YAML без коментарів — щоб зберегти коментарі, редагуйте текст.
- **Збереження з GUI.** «Зберегти поля в конфігурацію» на вкладці «Запуск» переносить заповнені поля форми запуску (сервери, кілька баз, схеми й таблиці, модуль, провайдер, режими…) у YAML — у поточний файл або новий; небезпечні режими й `-FromArchive` лишаються рішенням окремого запуску. Нову конфігурацію без файлу програма запропонує зберегти перед запуском.
- **Шаблони.** «Зберегти як шаблон» кладе налаштування в теку шаблонів (типово `%APPDATA%\IndexAdvisor\templates`, можна вказати спільну теку команди), за бажанням без серверів і баз. «Нова з шаблону» — вибрати шаблон (або стандартний шаблон модуля), вказати лише сервери й бази, за бажанням одразу зберегти у файл — і запускати.
- **Інструменти.** `New-IaIndexMaintenance` (скрипти AdaptiveIndexDefrag з архіву, винятки з `result.json`) і `Install-IaServiceLogin` (Verify — лише читання; Install, AddDatabase, Remove — з підтвердженням; облікові дані адміністратора SQL — у діалозі) з усіма параметрами й готовим командним рядком.
- **Параметри.** Тема, розмір шрифту, перенос і довжина журналу, модуль IndexAdvisor, політика виконання вбудованого PowerShell, тека шаблонів, автоперевірка конфігурації, звук і перехід до результатів після запуску, глибина пошуку `result.json`.
- **Результати.** Запуски з каталогу `output.path` (будь-яка глибина до трьох рівнів): статус і код, період даних, модель і вартість; рекомендації з фільтрами, обґрунтуванням, результатами перевірки, умовами видалення 4.4 і скриптами виконання й відкату (копіювання, збереження); знахідки правил, попередження, нотатки моделі, дозапити; кнопки HTML-звіту й теки запуску. Запуск без формату `Json` показується з пам'яті до закриття програми.

Модуль шукається так: шлях, вибраний на вкладці «Параметри» → `src\IndexAdvisor` у репозиторії над exe → копія `Modules\IndexAdvisor` поруч з exe (її кладе збірка). Відносні шляхи YAML розв'язуються від теки файлу конфігурації. Політика виконання вбудованого PowerShell — типово `RemoteSigned` для процесу. Розбір YAML у формі — тим самим powershell-yaml, що й модуль. Налаштування програми й форми (без секретів і без небезпечних режимів) — у `%APPDATA%\IndexAdvisor\gui-settings.json`.

## Обслуговування індексів (AdaptiveIndexDefrag)

Програма формує скрипти обслуговування індексів на базі [dbo.usp_AdaptiveIndexDefrag](https://github.com/microsoft/tigertoolbox/tree/master/AdaptiveIndexDefrag) з Microsoft Tiger Toolbox (перевірено з версією 1.7.5). Процедуру DBA встановлює окремо, за замовчуванням у `msdb` (`maintenance.procedureDatabase`).

```powershell
# Разом з аналізом
Invoke-IndexAdvisor -Config .\run.yaml -Maintenance

# З архіву вже зібраних даних, без нового збору й без LLM; result.json дає рекомендації на видалення
New-IaIndexMaintenance -FromArchive .\archive\20261110_080000_AGL-SALES_5f0c1a2b.zip -Config .\run.yaml -ResultPath .\out\...\result.json
```

Що з аналізу впливає на скрипти:

- пороги `rules.fragmentation` стають параметрами `@minFragmentation`, `@rebuildThreshold`, `@minPageCount`;
- ONLINE і RESUMABLE вмикаються за редакцією та версією інстансу; SORT_IN_TEMPDB — лише без RESUMABLE;
- порядок обробки — за кількістю range scans (якщо зібрано `usageStats`), інакше за фрагментацією;
- індекси, які запуск рекомендує видалити, стають винятками (`exclusionMask = -1`) у `dbo.tbl_AdaptiveIndexDefrag_Exceptions`;
- індекси, більші за `maintenance.largeIndexMb`, обслуговуються лише в дні `maintenance.largeIndexDays`, в інші дні діє `@maxPageCount`;
- бази AG обслуговуються лише на primary-репліці, усі бази — в межах спільного ліміту `maintenance.timeLimitMinutes`;
- у звіті є кандидати на REBUILD і REORGANIZE з розмірами та примітки (FILLFACTOR за частих розщеплень сторінок, повне журналювання в моделі FULL, офлайн-перебудова без Enterprise).

Файли в `maintenance/`:

- `index_maintenance.sql` — винятки й запуск процедури; за замовчуванням `@execPrint = 0` (лише друк команд для перегляду);
- `index_maintenance_rollback.sql` — видалення доданих винятків (є, лише якщо винятки є);
- `index_maintenance_job.sql` — завдання SQL Agent (розклад `maintenance.scheduleDays` о `maintenance.startTime`, другий крок — очищення журналів процедури); наявне завдання замінюється лише за `@replaceExisting = 1`;
- `index_maintenance_job_rollback.sql` — видалення завдання.

```yaml
maintenance:
  procedureDatabase: msdb
  jobName: IndexAdvisor - AdaptiveIndexDefrag
  scheduleDays: [Monday, Tuesday, Wednesday, Thursday, Friday, Saturday, Sunday]
  startTime: '01:00'
  timeLimitMinutes: 240
  largeIndexMb: 20480
  largeIndexDays: [Saturday, Sunday]
```

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

Тести GUI (xUnit: командний рядок, розбір `result.json`, хост PowerShell з діалогами, форма налаштувань і шаблони — з перевіркою через справжній `Test-IaConfig`, без серверів і моделі):

```powershell
dotnet test .\tests\Gui\IndexAdvisor.Gui.Tests
```
