# CONTRACTS.md — контракти AI Index Advisor

Єдине джерело вимог — `tz.md`. Цей файл фіксує, як частини системи стикуються між собою. **Змінює його лише оркестратор.** Субагент, якому потрібна зміна контракту (сигнатура, поле даних, формат, нова спільна функція), зупиняється й повідомляє оркестратора, нічого не змінюючи поза своїми теками.

## 0. Правила для потоків

| Потік | Теки (лише їх можна змінювати) |
|---|---|
| 1 Core | `src/IndexAdvisor/Core/`, `tests/Core/`, `tests/Security/` |
| 2 Collector | `src/IndexAdvisor/Collector/` (запити — `Collector/Queries/*.sql`), `tests/Collector/` |
| 3 Tools | `src/IndexAdvisor/Tools/` (інструменти — `Tools/Definitions/*.md`), `tests/Tools/` |
| 4 LLM | `src/IndexAdvisor/Llm/` (шаблони — `Llm/Prompts/*.md`), `tests/Llm/` |
| 5 Rules | `src/IndexAdvisor/Rules/`, `tests/Rules/` |
| 6 Output і CLI | `src/IndexAdvisor/Output/`, `src/IndexAdvisor/Cli/`, `sql/`, `bin/`, `tests/Output/`, `tests/Cli/` |
| Оркестратор | `CONTRACTS.md`, `QUESTIONS.md`, `README.md`, `src/IndexAdvisor/contracts/`, `src/IndexAdvisor/Shared/`, `IndexAdvisor.psd1`, `IndexAdvisor.psm1`, `tests/Fixtures/`, `tests/TestHelpers.ps1`, `tests/Module.Tests.ps1` |

- Заглушки контрактних функцій лежать у `<Тека>/<Тека>.Stubs.ps1` з точними сигнатурами. Реалізуючи функцію в окремому файлі, видаліть її заглушку; наприкінці потоку файл заглушок видаляється. Сигнатури заглушок — частина контракту: параметри не перейменовуються й не видаляються.
- Функції інших потоків викликайте лише через контрактні функції; у тестах — мокайте їх (`Mock -ModuleName IndexAdvisor <Функція>`). Не покладайтеся на те, що інший потік уже реалізований.
- Внутрішні (неконтрактні) функції потоку мають у назві іменника префікс потоку, щоб уникнути колізій: `Ia` + `Core|Col|Tool|Llm|Rule|Out|Cli` + Іменник (наприклад `Get-IaColQueryText`, `Format-IaOutSqlHeader`).
- Без класів PowerShell і без `using namespace` для зовнішніх збірок; типи ScriptDom і SqlClient не вживати в атрибутах параметрів (лише `[object]`), бо збірки завантажуються ліниво.
- Відкриті питання — у `QUESTIONS.md` (дописувати в кінець розділу свого потоку; формат: питання, прийняте найбезпечніше тлумачення).
- Мова: коментарі, повідомлення й тексти звітів — українською; ідентифікатори — англійською.
- T-SQL: ключові слова, функції й типи ВЕЛИКИМИ; відступи табами; рядок до 160 символів; змінні camelCase; кожна інструкція завершується `;`; права лише через ролі, ніколи GRANT логіну чи користувачу; перевірка ролі в базі — `IF USER_ID('db_rolename') IS NULL CREATE ROLE [db_rolename];`.
- Імена нових індексів у рекомендаціях: `IX_<Col1>[_D][_<Col2>...][_INC][_FLT][_UQ][_P]` (некластерний), `CI_...` (кластерний), `CS_...` (некластерний columnstore), `CCSI` (кластерний columnstore).

### Тестування (обов'язково)
- Лише юніт-тести Pester 5 з моками SQL (`Invoke-IaDbCommand`) і LLM (`Invoke-RestMethod` або `Invoke-IaLlmChat`); живі сервери й платні API не викликаються. ScriptDom — справжній (локальна збірка dbatools.library), не мокається.
- Кожен тест-файл починається з `BeforeAll { . (Join-Path $PSScriptRoot '..\TestHelpers.ps1') }`; помічники: `Get-IaTestSnapshot`, `Get-IaTestFixture`, `Get-IaTestConfig`, `Test-IaJsonAgainstSchema`. Неекспортовані функції викликаються через `InModuleScope IndexAdvisor { ... }` або `& (Get-Module IndexAdvisor) { ... }`.
- Після зміни запускати лише тести своєї теки: `Invoke-Pester -Path tests/<Тека>` (вивід — лише помилки). Повний набір свого потоку — один раз наприкінці.
- Тести з живим SQL Server чи реальними LLM — лише з тегом `Integration`; за замовчуванням не запускаються (`-ExcludeTagFilter Integration`).
- Той самий тест падає 3 рази поспіль — зупинитися, записати в `QUESTIONS.md`, перейти до іншої задачі.

## 1. Структура репозиторію

```
src/IndexAdvisor/
  IndexAdvisor.psd1 / .psm1     маніфест і завантажувач (Shared, Core, Collector, Tools, Llm, Rules, Output, Cli)
  Shared/Contracts.ps1          константи й конструктори канонічних об'єктів (оркестратор)
  Shared/ConfigSchema.psd1      схема YAML-конфігурації зі значеннями за замовчуванням (оркестратор)
  contracts/                    JSON-схеми: snapshot, recommendation, llm-response (усередині модуля: схема відповіді моделі
                                потрібна під час виконання; у цьому документі шлях скорочено до contracts/)
  Core/  Collector/Queries/  Tools/Definitions/  Llm/Prompts/  Rules/  Output/  Cli/
sql/Setup-IndexAdvisorLogin.sql, sql/Repository/IndexAdvisor.Repository.sql
bin/IndexAdvisor.ps1            точка входу CLI з кодами повернення
tests/<Тека>/*.Tests.ps1, tests/Security/, tests/Fixtures/, tests/TestHelpers.ps1
```

Залежності: `powershell-yaml`, `Microsoft.PowerShell.SecretManagement` (RequiredModules); `dbatools` завантажується ліниво (`Import-Module dbatools`) лише для реальних підключень і скрипта логіна. ScriptDom і Microsoft.Data.SqlClient беруться з `dbatools.library` (`<ModuleBase>/core/lib/`), якщо типи ще не завантажені.

## 2. Загальні конвенції даних

- Усі об'єкти даних — вкладені `[ordered]` хеш-таблиці з JSON-сумісними значеннями (рядок, число, bool, масив, `$null`). Масиви — завжди масиви (навіть з одного елемента). Серіалізація — `ConvertTo-Json -Depth 50`; читання — `ConvertFrom-Json -AsHashtable`.
- Дати — рядки ISO 8601 UTC `yyyy-MM-ddTHH:mm:ss.fffZ` (`ConvertTo-IaUtcString`). Запити колектора повертають UTC: локальні дати DMV перетворюються в SQL (`DATEADD(MINUTE, DATEDIFF(MINUTE, SYSDATETIME(), SYSUTCDATETIME()), col)`), datetimeoffset Query Store — через `SWITCHOFFSET(col, 0)` або на клієнті.
- Конфігурація — вкладена хеш-таблиця з ключами як у YAML (`$Config.limits.defaultFetch`). Повна структура й значення за замовчуванням — `Get-IaDefaultConfig` (з `Shared/ConfigSchema.psd1`).
- Ціль (`New-IaTarget`): `{ server, database, schema, table, index, objectKey }`. `server` — ім'я AG для баз в AG, інакше `@@SERVERNAME`. `objectKey` — `Get-IaObjectKey` (`server|database|schema.table|index` у нижньому регістрі; для таблиці index порожній).
- Помилки конвеєра SQL не кидаються, а повертаються в конверті. Помилки політики й конфігурації — винятки з `ErrorId`: `IaLoginRefused`, `IaConfigInvalid`, `IaSecretNotFound`, `IaBudgetExceeded`, `IaProviderNotAllowed`, `IaToolDefinitionInvalid`, `IaArchiveInvalid`, `IaCollectionFailed` (код процесу 4) (через `$PSCmdlet.ThrowTerminatingError` або `Write-Error -ErrorId ... -ErrorAction Stop`).
- Шви для моків: `Invoke-IaDbCommand` (SQL, цільові сервери), `Invoke-IaOutRepositoryCommand` (SQL, репозиторій), `Invoke-RestMethod` (LLM), `Get-Secret`/`Set-Secret` (сховище), `Read-IaToolUserInput` (діалог підтвердження, потік Tools).
- `Invoke-IaDbCommand` повідомляє про помилку terminating-винятком з `ErrorId` = код конверта (`Timeout`, `ConnectionFailed`, `SqlError`), повідомлення сервера — у `TargetObject.messages`. У моках: `Write-Error -ErrorId Timeout -Message '...' -ErrorAction Stop`.
- За замовчуванням `connection.authentication = Sql`, тож тести, що проходять через справжній `Invoke-IaSqlQuery`, мокають `Get-IaSecret` (інакше конверт `ConnectionFailed` без виклику драйвера). `Invoke-IaSqlQuery` сам відхиляє `Purpose FreeQuery` без `unsafe.allowFreeQuery` і нештатний логін без `unsafe.allowNonStandardLogin`.

## 3. Контрактні функції

Точні сигнатури — у файлах заглушок; тут — призначення й результат. Експортуються лише `Invoke-IndexAdvisor`, `New-IaConfigTemplate`, `Test-IaConfig`, `Install-IaServiceLogin`.

### 3.0 Shared (оркестратор, реалізовано)
`Get-IaConfigSchema`, `Get-IaDefaultConfig`, `ConvertTo-IaUtcString`, `Get-IaObjectKey`, `New-IaTarget`, `New-IaResponse`, `New-IaError`, `New-IaFinding`, `New-IaRecommendation`, `New-IaRunResult`, `Copy-IaObject`. Константи: `$script:IaDatasetNames`, `$script:IaMandatoryDatasets`, `$script:IaActions`, `$script:IaExitCodes`, `$script:IaErrorCodes`, `$script:IaToolVersion`, `$script:IaModuleRoot`.

### 3.1 Core
| Функція | Результат |
|---|---|
| `Invoke-IaSqlQuery -Server -Database -Query [-Parameters] [-Fetch] [-Skip] [-Purpose] [-ApplicationIntent] [-Config]` | Конверт (5.10). Єдиний конвеєр для колектора й інструментів (розділ 3.1.1). `-Config` за замовчуванням — з поточної сесії, інакше `Get-IaDefaultConfig`. |
| `Invoke-IaDbCommand -ConnectionString -CommandText [-Parameters] [-CommandTimeoutSeconds] [-MaxRows]` | Шов драйвера: `{ columns = @(@{name; type}); rows = @(,[object[]]); messages; hasMoreRows }`. Відкриває й закриває підключення в межах виклику. Мережевий обрив або тайм-аут до входу (pre-login: 10053, 10054, 10060, 10061, 64, 121, 233, -2) — до двох повторів через 1 і 3 с, кожен записується в `messages`; помилки входу не повторюються. |
| `Test-IaSelectOnly -Sql` | `{ isValid; statementCount; errors }` — рівно один батч, одна `SelectStatement` без `INTO`. |
| `Test-IaSystemSourcesOnly -Sql` | `{ isValid; errors }` — джерела лише `sys.*`, `INFORMATION_SCHEMA.*`, CTE і вбудовані функції. |
| `ConvertTo-IaSqlFragment -Sql` | `{ fragment; errors; parserName }` — для валідації синтаксису (Rules) і очищення літералів (LLM). |
| `Get-IaScriptDomParser` | Екземпляр найновішого `TSqlNNNParser` (≥ 150). |
| `New-IaConnectionString -Server -Database -Config [-ApplicationIntent]` | Рядок підключення (не логувати). |
| `Assert-IaStandardLogin -Config` | Політика штатного логіна (розділ 3.1.2). |
| `Get-IaLoginPermissions -Server -Database -Config` | Фактичні й зайві права логіна. |
| `Start-IaSession`, `Get-IaSession`, `Stop-IaSession`, `Write-IaLog` | Сесія й Markdown-журнал (5.11). |
| `Protect-IaLogValue -Name -Value` | Маскування за іменем (`password`, `pwd`, `secret`, `token`, `key`, `api_key`, `connection_string`). |
| `Get-IaUnsafeFlags -Config` | Імена активних прапорців `unsafe.*`. |
| `ConvertTo-IaJsonValue -Value` | decimal → рядок, дати → ISO 8601 UTC, guid → рядок, byte[] → base64, DBNull → `$null`. |

#### 3.1.1 Конвеєр `Invoke-IaSqlQuery` (розділ 4.7 ТЗ), порядок кроків
1. Перевірка аргументів до підключення: `Server`, `Database`, `Query` непорожні (`ArgumentInvalid`); довжина `Query` ≤ `limits.maxCommandLength` (`CommandTooLong`); `Fetch` ≥ 0 і `Skip` ≥ 0 (`ArgumentInvalid`).
2. `Fetch`: `$null` → `limits.defaultFetch`; більше `limits.maxRows` → обрізається до `maxRows` з повідомленням у `messages`; більше `limits.largeResultWarningRows` → попередження про обсяг контексту й вартість токенів (`messages` і `Write-Warning`).
3. `Test-IaSelectOnly` (якщо не `unsafe.disableSelectCheck`) → `NotSingleSelect`; `Test-IaSystemSourcesOnly` (завжди) → `ForbiddenSource`.
4. Параметри: лише іменовані `@Name`. Ключі `-Parameters` приймаються з `@` або без. Значення передаються драйверу як `SqlParameter`; склеювання значень у текст заборонене. Параметр у `-Parameters`, якого немає в тексті, — `UnknownParameter`; змінна `@Name` у тексті без значення — `MissingParameter`.
5. Ліміт рядків: вставка `TOP (Fetch + 1)` після SELECT верхнього рівня (якщо `Skip` = 0) або `OFFSET Skip ROWS FETCH NEXT Fetch + 1 ROWS ONLY` (якщо `Skip` > 0; без ORDER BY додається `ORDER BY (SELECT NULL)`); наявний TOP зменшується до ліміту. Додатково драйвер читає не більше `Fetch + 1` рядків. `truncated = $true`, якщо прочитано більше `Fetch`.
6. `OPTION (MAXDOP 1)` додається до запиту (злиття з наявним OPTION), якщо не `unsafe.disableMaxdop`. Модифікація — через AST ScriptDom і `Sql160ScriptGenerator` (або точкові вставки за позиціями фрагментів).
7. Префікс сесії перед запитом у тому самому батчі:
   ```sql
   SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
   SET LOCK_TIMEOUT <connection.lockTimeoutMs>;
   SET DEADLOCK_PRIORITY LOW;
   ```
8. Рядок підключення `New-IaConnectionString`; `CommandTimeout` = `connection.commandTimeoutSeconds` (0, якщо `unsafe.disableTimeouts`; LOCK_TIMEOUT при цьому лишається).
9. Виклик `Invoke-IaDbCommand`; нормалізація рядків у `[ordered]` словники `колонка → ConvertTo-IaJsonValue` (дублікати імен колонок → суфікс `_2`, `_3`).
10. Журнал (5.11) для кожного виклику, зокрема заблокованого. Підключення закривається після кожного виклику (Pooling = false).

#### 3.1.2 Штатний логін (розділ 6 ТЗ)
- `connection.authentication = Sql`: логін — `connection.login`; `Windows`: логін — поточний `DOMAIN\user`.
- Якщо логін ≠ `security.standardLogin` (без урахування регістру) і `unsafe.allowNonStandardLogin = $false` — виняток `IaLoginRefused` з поясненням причини і як увімкнути прапорець.
- Якщо прапорець увімкнено — повертається `isStandard = $false`; викликач (CLI) для кожного сервера й бази викликає `Get-IaLoginPermissions`, показує попередження з переліком зайвих прав (sysadmin, db_owner, db_datareader, db_datawriter, CONTROL, ALTER, INSERT/UPDATE/DELETE тощо) і пише їх у журнал (`Level = Security`).

### 3.2 Collector
| Функція | Результат |
|---|---|
| `Get-IaTopology -Server -Config` | `topology` (snapshot.schema.json). Один SELECT: `SERVERPROPERTY('IsHadrEnabled')`, `SERVERPROPERTY('IsClustered')`, `@@SERVERNAME`, `sys.availability_groups`, `sys.availability_replicas`, `sys.dm_hadr_availability_replica_states` (LEFT JOIN). |
| `Get-IaDatasetSelection -Config` | `{ enabled; disabled; warnings }`; попередження про зниження достовірності для кожного вимкненого набору. |
| `Invoke-IaCollection -Server -Config -AnalysisWindow` | Snapshot. Для AG — підключення до кожної репліки напряму за `connectAddress` (FQDN хоста з `read_only_routing_url`/`endpoint_url`, якщо він починається з імені репліки, інакше коротке ім'я + домен запитаного сервера чи listener), а якщо його не визначено — за `replicaServerName`; для standalone/FCI — до вказаного інстансу. `ApplicationIntent` не задається, крім вторинної репліки з `secondaryAllowConnections = READ_ONLY` (тоді `ReadOnly`); `NO` — репліка пропускається з `skipReason`. Query Store читається з primary. Великі набори — сторінками (`Fetch = limits.maxRows`, `Skip`), запити мають детермінований ORDER BY. physical_stats — LIMITED, по індексах, у межах `collector.physicalStatsTimeBudgetSeconds`; решта позначається `skipped`. Плани Query Store розбираються в PowerShell (XML showplan) у `plans[].indexOperations/missingIndexes/predicates/...` та `index.queryStoreUsage`; сирий XML у snapshot не потрапляє. Хінти: пошук імен індексів у `sys.sql_modules.definition` і в текстах Query Store. |
| `Save-IaSnapshotArchive -Snapshot -Prompts -MaskingMap -RunId -Config` | Шлях ZIP або `$null`. Вміст і правила — розділ 5.12. |
| `Read-IaSnapshotArchive -Path` | `{ manifest; snapshot; prompts; maskingMap }`. |
| `Remove-IaExpiredArchives -Config` | Видалені шляхи. |

Усі запити колектора — `Collector/Queries/<name>.sql`, кожен — одна інструкція SELECT з системних каталогів/DMV/Query Store, з параметрами `@Name`, і виконуються лише через `Invoke-IaSqlQuery -Purpose Collector`.

### 3.3 Tools
| Функція | Результат |
|---|---|
| `Import-IaToolDefinitions [-Path] -Config` | `[ordered]` назва → ToolDefinition (розділ 6). |
| `ConvertFrom-IaToolMarkdown -Path` | ToolDefinition або виняток `IaToolDefinitionInvalid`. |
| `ConvertTo-IaToolJsonSchema -Tool` | `{ name; description; parameters = { type = 'object'; properties; required; additionalProperties = $false } }`. |
| `Test-IaToolArguments -Tool -Arguments` | `{ isValid; errors; arguments }`. |
| `Invoke-IaTool -Tool -Arguments -Server -Database [-Fetch] [-Skip] -Config [-ApplicationIntent]` | Конверт (через `Invoke-IaSqlQuery -Purpose Tool`, для `free_query` — `FreeQuery`). `ApplicationIntent = ReadOnly` — для вторинної репліки з `secondaryAllowConnections = READ_ONLY` (визначає цикл). |
| `Request-IaToolApproval -ToolRequest -Tools -Config` | `{ decision = Approved|Modified|Rejected|AutoApproved; toolRequest; reason }`. Користувач може підтвердити, змінити (аргументи, fetch, skip) або відхилити. Діалог — через внутрішню `Read-IaToolUserInput` (мокається). |
| `Invoke-IaAnalysisLoop -Prompt -Snapshot -ProviderConfig -Tools [-MaskingMap] -Config` | LlmAnalysisResult (5.6). |

Цикл `Invoke-IaAnalysisLoop`: `Invoke-IaLlmChat` → `ConvertFrom-IaLlmResponse` → для кожного `toolRequest`: розмаскування (`ConvertFrom-IaMaskedObject`), перевірка інструмента й аргументів, перевірка, що `server`/`database` є серед зібраних у snapshot (інакше `Blocked`), `Request-IaToolApproval`, `Invoke-IaTool`, маскування результату (`ConvertTo-IaMaskedObject`) → додавання в розмову як повідомлення `user` з JSON результату → наступний виклик. Зупинка: відповідь без `toolRequests` (`Completed`), вичерпано `limits.maxToolRequestsPerAnalysis` (`ToolLimit`; моделі надсилається останній запит «дай фінальну відповідь без дозапитів»), `limits.maxTokensPerAnalysis` (`TokenLimit`), `IaBudgetExceeded` (`BudgetExceeded`), помилка (`Error`). Рекомендації фінальної відповіді розмасковуються.

### 3.4 LLM
| Функція | Результат |
|---|---|
| `Get-IaSecret -Reference [-AsPlainText]` | SecureString або рядок. SecretRef: `env:NAME`, `secret:Name`, `secret:Vault/Name`. |
| `Test-IaSecretReference -Reference` | bool. |
| `Get-IaLlmProviderConfig -Name -Config [-IgnoreModelOverride]` | Провайдер (значення за замовчуванням зі схеми + `name`). |
| `Assert-IaProviderAllowed -ProviderConfig -Config` | Режим `llm.localOnly`. |
| `Invoke-IaLlmChat -ProviderConfig -Messages [-MaxTokens] [-JsonResponse] [-Purpose] -Config` | LlmResponse (5.5). REST: OpenAI `/v1/chat/completions`, Azure OpenAI `/openai/deployments/{model}/chat/completions?api-version=`, Anthropic `/v1/messages`, Cohere `/v2/chat`, OpenAICompatible — як OpenAI з `endpoint`. Повтори з експоненційною паузою на 429/5xx/таймаут. Anthropic з `promptCaching` (за замовчуванням): `system` — масив блоків з `cache_control` на системному промпті й `cache_control` на рівні запиту (автоматичне кешування діалогу). Обрізана відповідь (`finishReason` `max_tokens`, `length`, `MAX_TOKENS`) з неповним JSON — помилка циклу з поясненням про `maxTokensPerRequest`. Бюджет — облік у `llm.budgetLedgerPath` (JSON: записи `{ utc; provider; model; inputTokens; outputTokens; costUsd; purpose }`). |
| `Get-IaBudgetStatus`, `Get-IaLlmCost`, `Measure-IaTokens` | Облік токенів і вартості. |
| `New-IaMaskingMap`, `ConvertTo-IaMaskedObject`, `ConvertFrom-IaMaskedObject`, `Remove-IaSqlLiterals` | Маскування (розділ 5.13). |
| `New-IaLlmContext -Snapshot -Findings -Module -ProviderConfig -Config [-ReservedTokens]` | `{ payload; includedObjectKeys; truncatedObjects; estimatedTokens; module }`. В модель іде лише `payload`. Бюджет таблиць — 0,8 × `maxContextTokens` мінус `ReservedTokens` (чернетки модуля партиціонування); `Measure-IaTokens` — 1,8 байта UTF-8 на токен. Пріоритет при стисненні: таблиці зі знахідками rules engine і з топ-запитами Query Store. |
| `Get-IaPromptTemplate -Name [-Version]` | `{ id; version; system; user; path }`. Файли `Llm/Prompts/<name>.v<N>.md`. |
| `New-IaPrompt -TemplateName -Payload [-ToolSchemas] -Config` | Prompt (5.12). |
| `ConvertFrom-IaLlmResponse -Text` | `{ recommendations; toolRequests; draftDecisions; notes; parseErrors }` (contracts/llm-response.schema.json). |
| `Invoke-IaCrossCheck -Recommendations -Payload [-MaskingMap] -Config` | `{ recommendations; calls }` — критичні (DropIndex або risk High) перевіряються моделлю `llm.crossCheckProvider`. |

### 3.5 Rules
| Функція | Результат |
|---|---|
| `Invoke-IaRulesEngine -Snapshot -Config` | RuleFinding[] (5.2): `DuplicateIndex`, `OverlappingIndex`, `UnusedIndex`, `WriteOnlyIndex`, `MissingIndexCandidate`, `TooManyIndexes`, `Fragmentation`, `ExpensiveIndex`. |
| `Merge-IaMissingIndexes -Snapshot -Config` | Злиті кандидати missing index (розділ 4.5). |
| `Get-IaIndexCreateEstimate -Table -KeyColumns [-IncludedColumns] [-UptimeDays]` | `{ estimatedSizeMb; estimatedBuildMinutes; tableWritesPerDay }`. |
| `Get-IaAnalysisWindow -Config [-NowUtc]` | `{ fromUtc; toUtc; mode; reason }` (розділ 4.4: на початку місяця — весь попередній місяць). |
| `Get-IaDataPeriod -Snapshot -Config` | DataPeriod[] (5.3) для кожного інстансу і бази. |
| `Test-IaExpensiveIndex -Index -Config` | `{ isExpensive; reasons }`. |
| `Get-IaDropEligibility -Recommendation -Snapshot -History -DataPeriods -Config [-NowUtc]` | DropEligibility (5.4). |
| `Test-IaRecommendation -Recommendation -Snapshot -Config` | Validation (розділ 4.8; id перевірок — recommendation.schema.json). |
| `Invoke-IaPartitionAnalysis -Snapshot -Config` | `{ findings; drafts }` — чернетки у форматі llm-response з `partitioning`. |
| `New-IaObjectVerdicts -RunId -Module -Recommendations -IncludedObjectKeys -DataPeriods -Config` | IndexVerdict[] (5.7). |

Правила 4.4 (стисло): серія — N зарахованих аналізів поспіль з вердиктом `DropRecommended`; будь-який `Keep` (навіть з короткого періоду) обнуляє серію; аналіз зараховується, лише якщо період ≥ `minUptimeDays` (з урахуванням `observationOverrides`) і з моменту попереднього зарахованого минуло ≥ `minIntervalDays`; структурні умови (PK, UNIQUE, FK з обох боків — `referencedByForeignKeys` і `coversForeignKeys`, реплікація, хінти, невикористання в Query Store, перевірено на всіх репліках AG з `collected = true`) не пом'якшуються; невідоме значення (`$null`) — умова не виконана. Пом'якшений профіль (`rules.relaxed`) — для індексів, де `Test-IaExpensiveIndex` повертає `isExpensive`.

### 3.6 Output
| Функція | Результат |
|---|---|
| `Export-IaReport -RunResult -Config` | Файли в `output.path/<yyyyMMdd_HHmmss>_<server>_<runId8>/`: `recommendations.md`, `sql/NNN_<action>_<table>_<index>.sql` і `sql/NNN_..._rollback.sql`, `report.html`, `result.json`; `Console` — підсумок у консоль. Розділ 9. |
| `Save-IaRunToRepository -RunResult -Config` | Запис у репозиторій (розділ 8) через внутрішню `Invoke-IaOutRepositoryCommand` (параметризовані INSERT/DELETE лише в базу `repository.database`; відмова, якщо ця база є серед цільових). |
| `Get-IaRecommendationHistory -ObjectKeys -Module -Config` | IndexVerdict[] з репозиторію. |
| `Remove-IaExpiredHistory -Config` | Кількість видалених запусків. |
| `Get-IaMaintenancePlan -Snapshot -Config [-Recommendations] [-RunId]` | План обслуговування для `dbo.usp_AdaptiveIndexDefrag` (Tiger Toolbox, перевірено з 1.7.5): для кожної бази ONLINE (AG — з primary) кандидати REBUILD/REORGANIZE за `physical` і `rules.fragmentation`, винятки (`DropIndex`, не `Failed` → `exclusionMask = -1`, за `excludeDropCandidates`), параметри процедури (ONLINE/RESUMABLE за `supportsOnlineIndexOps` і версією ≥ 14, `@defragOrderColumn = range_scan_count`, якщо зібрано `usageStats`), примітки. Великі індекси (`maintenance.largeIndexMb`) — лише в `largeIndexDays`, в інші дні `@maxPageCount`. Записується в `RunResult.maintenance`. |
| `Export-IaMaintenanceFiles -Plan -Directory` | `maintenance/index_maintenance.sql` (винятки + запуск; `@execPrint = 0` — лише друк), `index_maintenance_rollback.sql` (якщо є винятки), `index_maintenance_job.sql` (SQL Agent; заміна наявного лише за `@replaceExisting = 1`), `index_maintenance_job_rollback.sql`. `Export-IaReport` викликає її, якщо `RunResult.maintenance` не `$null`, і додає розділ «Обслуговування індексів» у звіт. |
| `New-IaIndexMaintenance -FromArchive [-Config] [-ResultPath] [-OutputPath] [-PassThru]` | Публічна команда: план і скрипти з архіву без збору й LLM; `-ResultPath` — `result.json`, з якого беруться рекомендації `DropIndex`. Каталог `output.path/<час>_<server>_maintenance/` з `maintenance/*.sql` і `maintenance_plan.md`. |

### 3.7 CLI
| Функція | Результат |
|---|---|
| `Invoke-IndexAdvisor ...` | Конвеєр розділу 4; `$global:LASTEXITCODE`; `-PassThru` → RunResult[]. |
| `Get-IaConfig -Path -Overrides` | Перевірена конфігурація (розділ 7). |
| `Test-IaConfig -Path` | `{ isValid; errors = @(@{ line; column; path; message }) }`. |
| `New-IaConfigTemplate [-Path] [-Force]` | YAML-шаблон з усіма ключами, значеннями за замовчуванням і коментарями з `Description`. |
| `Install-IaServiceLogin -SqlInstance -Mode ...` | Обгортка скрипта логіна (розділ 10). |

## 4. Конвеєр `Invoke-IndexAdvisor`

1. `Get-IaConfig` (YAML + CLI) → помилка: код `ConfigError`.
2. `Start-IaSession`; активні `Get-IaUnsafeFlags` → `Write-Warning` + журнал.
3. `Assert-IaStandardLogin` → `IaLoginRefused`: код `ConnectionRefused`.
4. Для кожного сервера з `servers` (окремий запуск, окремий RunResult, окремий архів):
   1. `New-IaRunResult`; `Get-IaAnalysisWindow`.
   2. `-FromArchive`: `Read-IaSnapshotArchive` (якщо є мапа — `ConvertFrom-IaMaskedObject` для snapshot; немає — попередження, далі з маскованими іменами). Інакше `Invoke-IaCollection` (+ `Get-IaLoginPermissions`, якщо логін не штатний).
   3. `Get-IaDataPeriod`; короткий період → попередження в звіті.
   4. Модуль Indexes: `Invoke-IaRulesEngine`. Модуль Partitioning: `Invoke-IaPartitionAnalysis` (незалежно).
   5. `Get-IaLlmProviderConfig` + `Assert-IaProviderAllowed`; `Import-IaToolDefinitions`; `New-IaMaskingMap`.
   6. Для кожного модуля: `New-IaLlmContext` → `ConvertTo-IaMaskedObject` (payload) → `New-IaPrompt` (`index-analysis` або `partition-analysis`; для партиціонування в payload додаються компактні `drafts` модуля — з `draftId` і без SQL-скриптів, у межах бюджету контексту; модель повертає `draftDecisions`, і `Merge-IaCliDraftDecisions` перетворює чернетки з `Confirm` або без рішення на рекомендації правил, а з `Reject` — відкидає з попередженням).
   7. `ConvertTo-IaMaskedObject` (snapshot) → `Save-IaSnapshotArchive` (не для `-FromArchive`). Без маскування імен — попередження про немасковані тексти запитів і структуру баз.
   8. `Invoke-IaAnalysisLoop` → `New-IaRecommendation` для кожної чернетки.
   9. `llm.crossCheckProvider` → `Invoke-IaCrossCheck`.
   10. Для кожної рекомендації: `dataPeriod` (відповідної бази), `Test-IaRecommendation`; для DropIndex — `Get-IaRecommendationHistory` + `Get-IaDropEligibility`; `warnings` += активні unsafe-прапорці, попередження вимкнених наборів, короткого періоду, неповних умов 4.4.
   11. `New-IaObjectVerdicts`; `Get-IaMaintenancePlan` (якщо `maintenance.enabled`; збій — попередження); `Export-IaReport`; `Save-IaRunToRepository` (якщо `repository.enabled`); `Remove-IaExpiredHistory`; `Remove-IaExpiredArchives`.
5. `Stop-IaSession`; код повернення — найгірший серед запусків (розділ 11).

## 5. Об'єкти даних

### 5.1 Snapshot — `contracts/snapshot.schema.json`; приклад — `tests/Fixtures/snapshot.sample.json`
Ключові правила: один snapshot на запитаний сервер; `instances[]` — кожна зібрана репліка окремо (статистика використання своя на кожній); набір не зібрано → відповідні поля `null` (не нулі); `masking` — `{ namesMasked; literalsMasked }` (у сирому snapshot обидва `false`).

### 5.2 RuleFinding — `New-IaFinding`
`{ findingId; ruleId; severity = Info|Low|Medium|High; target; relatedIndexes; message; details; suggestedAction }`. Для `MissingIndexCandidate` `details` містить `keyColumns`, `includedColumns`, `sourceIndexHandles`, `estimate`.

### 5.3 DataPeriod — recommendation.schema.json `$defs.dataPeriod`
Один на інстанс (`database = $null`) і на кожну базу. `statsFromUtc = max(sqlserverStartTimeUtc, lastFailoverUtc)`; `minRequiredDays` — з `rules.drop.minUptimeDays` або найточнішого `observationOverrides`; `isSufficient = uptimeDays ≥ minRequiredDays`. Для AG `server` — ім'я AG, для бази береться найкоротший період серед зібраних реплік.

### 5.4 DropEligibility — recommendation.schema.json `$defs.dropEligibility`
`conditions[].id`: `ConsecutiveSeries`, `MinUptimePeriod`, `MinInterval`, `AnalysisWindow`, `NotPrimaryKey`, `NotUnique`, `NoForeignKeySupport`, `NotReplicated`, `NoHintReferences`, `NotUsedInQueryStore`, `CheckedOnAllReplicas`. `isEligible` — усі `met = $true`. `warning` — текст на кшталт «Ґрунтується на 1 з 3 аналізів; період 70.2 дн. (з 2026-09-01); бракує 2 підтверджень».

### 5.5 LlmResponse
`{ llmCallId; provider; model; purpose; text; inputTokens; outputTokens; cacheWriteTokens; cacheReadTokens; costUsd; durationMs; finishReason; createdAtUtc; promptTemplateId; promptTemplateVersion; success; error }`; `error` — рядок або `$null`. `inputTokens` — повний розмір промпту (у тому числі запис у кеш і читання з кешу); `costUsd` рахує некешований вхід, запис і читання кешу за своїми цінами (`cacheWritePricePer1MTokensUsd`, `cacheReadPricePer1MTokensUsd`; 0 — 1,25 і 0,1 ціни входу для Anthropic, 0,5 для читання в інших).
`New-IaLlmContext.truncatedObjects` — масив `@{ objectKey; reason = Omitted|Reduced }`.
Помилки з `ErrorId` мають `FullyQualifiedErrorId` вигляду `IaXxx,<Функція>`: перевіряти `-like 'IaXxx*'`.

### 5.6 LlmAnalysisResult і ToolRequestRecord
LlmAnalysisResult: `{ recommendations (чернетки, розмасковані); draftDecisions (рішення щодо чернеток модуля: `{ draftId; decision = Confirm|Reject; reason }`); notes; calls = @(LlmResponse без text); toolRequests = @(ToolRequestRecord); totalInputTokens; totalOutputTokens; totalCostUsd; stoppedReason = Completed|ToolLimit|TokenLimit|BudgetExceeded|Error; error; prompt = @{ templateId; templateVersion } }`.
ToolRequestRecord: `{ toolRequestId; llmCallId; tool; server; database; arguments; fetch; skip; reason; decision = Approved|Modified|Rejected|AutoApproved|Blocked; decisionReason; response = @{ success; rowCount; truncated; durationMs; error } або $null; executedAtUtc }`.

### 5.7 IndexVerdict
`{ runId; objectKey; module; analyzedAtUtc; verdict = DropRecommended|Keep; countsTowardSeries; periodDays; rulesProfile = Standard|Relaxed|null }`.

### 5.8 Recommendation — `contracts/recommendation.schema.json`, конструктор `New-IaRecommendation`
Рекомендація, що не пройшла перевірку 4.8, не видаляється, а має `validation.status = Failed` з причинами і показується в окремому розділі звіту «Відхилені перевіркою».

### 5.9 RunResult — `New-IaRunResult`
Поля див. у конструкторі. `status = Succeeded|Partial|Failed`; `exitCode` — розділ 11. `llm.notes` — масив `@{ module; text }` (нотатки моделі, показуються у звітах); `errors` — масив `@{ stage; code; exitCode; message }`, де `code` — ключ `$script:IaExitCodes`.

### 5.10 Конверт відповіді — `New-IaResponse`
`{ success; requestId; server; database; durationMs; rowCount; truncated; columns = @(@{ name; type }); rows = @([ordered] колонка → значення); messages = @(рядки); error = New-IaError або $null }`.

### 5.11 Сесія і журнал
Сесія: `{ sessionId; startedAtUtc; logPath; config; unsafeFlags; command }`. Журнал — Markdown, один файл на сесію. Заголовок: сесія, користувач, хост, команда, параметри (санітизовані), активні unsafe-прапорці. Для кожного виклику SQL — розділ `### <requestId>` з полями: початок, завершення, тривалість, сервер, база, Purpose, Fetch, Skip, кількість рядків, truncated, успіх, параметри (`Protect-IaLogValue`), повний текст запиту (у ```sql-блоці, з префіксом і модифікаціями), помилка.

### 5.12 Prompt і архів
Prompt: `{ templateId; templateVersion; messages = @(@{ role; content }); toolSchemas; responseSchema }`. Модель повертає JSON за `contracts/llm-response.schema.json`.
ZIP `archive.path/<yyyyMMdd_HHmmss>_<server>_<runId8>.zip`: `manifest.json` `{ schemaVersion; runId; snapshotId; createdAtUtc; toolVersion; requestedServer; namesMasked; literalsMasked; promptTemplates = @(@{ id; version }); warning }`, `snapshot.json`, `prompts/<templateId>.json`. Мапа маскування — `<те саме ім'я>.map.json` поруч із ZIP (не всередині). Каталог створюється з обмеженням NTFS (`archive.restrictAcl`: лише поточний користувач, SYSTEM і Administrators, без успадкування). Без маскування імен — `manifest.warning` і `Write-Warning`: архів містить немасковані тексти запитів і структуру баз, його не можна передавати в зовнішні сервіси без перевірки.

### 5.13 Маскування
Літерали в текстах запитів (`queryText`, тексти T-SQL у payload) очищуються завжди (`Remove-IaSqlLiterals`). Імена (сервер, AG, база, схема, таблиця, колонка, індекс, FK, модуль) маскуються при `llm.maskNames`: псевдоніми `srv1`, `db1`, `sch1`, `tbl1`, `col1`, `ix1`, `fk1`, `mod1`; заміна в текстах запитів — за токенами-ідентифікаторами ScriptDom. Розмаскування — заміна псевдонімів назад за мапою, зокрема в T-SQL рекомендацій.

## 6. Формат Markdown-інструменту (`Tools/Definitions/<name>.md`)

```markdown
# index_usage_stats

## Description
Статистика використання індексів таблиці з sys.dm_db_index_usage_stats.

## Method
Query

## Server

## Database

## Parameters
- @SchemaName: string {maxLength=128} - Схема таблиці
- @TableName: string {maxLength=128} - Ім'я таблиці
- @MinUpdates: int? {min=0, max=2147483647, default=0} - Мінімум updates

## Query
```sql
SELECT ...
WHERE s.name = @SchemaName AND t.name = @TableName;
```
```

- `# <name>` — назва: `^[a-z][a-z0-9_]{2,63}$`, унікальна.
- `## Method` — лише `Query` (read-only SELECT).
- `## Server` / `## Database` — необов'язково зафіксовані значення; порожньо — з дозапиту моделі.
- Параметр: `- @<Name>: <type>[?] [{attr=value, ...}] - <опис>`; `?` — необов'язковий. Типи: `string`, `int`, `bigint`, `decimal`, `bool`, `datetime`, `guid`. Атрибути: `enum=A|B|C`, `min`, `max`, `maxLength`, `default`. JSON-схема: `string` → `string`, `int`/`bigint` → `integer`, `decimal` → `number`, `bool` → `boolean`, `datetime` → `string` (`format: date-time`), `guid` → `string` (`format: uuid`); `additionalProperties = false`; ім'я властивості — без `@`.
- `## Query` — рівно один ```sql-блок; кожна `@Name` у запиті має бути оголошена в Parameters і навпаки.
- Fetch і Skip — не параметри інструмента, а поля дозапиту (`fetch`, `skip`).
- Вбудований набір: `table_structure`, `index_usage_stats`, `index_operational_stats`, `missing_indexes`, `query_store_top_queries`, `query_store_plans`, `query_store_predicates`, `size_and_partitions`. `free_query` (параметр `@Sql`, Purpose FreeQuery) — лише при `unsafe.allowFreeQuery`.

## 7. YAML-конфігурація

Схема — `src/IndexAdvisor/Shared/ConfigSchema.psd1` (ключі, типи, enum, min/max, значення за замовчуванням, описи для шаблону). Правила перевірки: невідомий ключ, неправильний тип, значення поза enum/min/max, відсутній обов'язковий ключ — помилка з номером рядка і стовпця (позиції з YamlDotNet, що входить у powershell-yaml); значення ключа з `Secret = $true` має бути SecretRef (`Test-IaSecretReference`), інакше помилка «секрети не зберігаються в YAML».

Пріоритет: значення за замовчуванням < YAML < параметри CLI. Відповідність параметрів CLI:

| CLI | Ключ |
|---|---|
| `-Server` | `servers` |
| `-Database` / `-ExcludeDatabase` | `scope.databases.include` / `.exclude` |
| `-Schema` / `-ExcludeSchema` | `scope.schemas.include` / `.exclude` |
| `-Table` / `-ExcludeTable` | `scope.tables.include` / `.exclude` |
| `-Module` | `module` |
| `-Provider` / `-Model` / `-CrossCheckProvider` | `llm.provider` / `llm.model` / `llm.crossCheckProvider` |
| `-AnalysisWindowDays` | `analysisWindow.days` |
| `-Dataset` | `collector.datasets.*` = `$true` лише для перелічених (+ обов'язкові), решта `$false` |
| `-ExcludeDataset` | `collector.datasets.<name>` = `$false` |
| `-OutputPath` / `-Format` | `output.path` / `output.formats` |
| `-NoRepository` | `repository.enabled = $false` |
| `-NoArchive` | `archive.enabled = $false` |
| `-NonInteractive` / `-AutoApprove` | `run.nonInteractive` / `llm.autoApproveToolRequests` |
| `-LocalOnly` / `-MaskNames` | `llm.localOnly` / `llm.maskNames` |
| `-Maintenance` | `maintenance.enabled = $true` |
| `-UnsafeDisableSelectCheck`, `-UnsafeDisableMaxdop`, `-UnsafeDisableTimeouts`, `-UnsafeAllowFreeQuery`, `-AllowNonStandardLogin` | `unsafe.disableSelectCheck`, `unsafe.disableMaxdop`, `unsafe.disableTimeouts`, `unsafe.allowFreeQuery`, `unsafe.allowNonStandardLogin` |

## 8. Схема репозиторію (база `IndexAdvisor`, схема `Advisor`)

Скрипт `sql/Repository/IndexAdvisor.Repository.sql` — ідемпотентний; права — роль бази `db_index_advisor` (SELECT, INSERT, UPDATE, DELETE на `SCHEMA::[Advisor]`), членство логіна в ролі, без прямих GRANT. Сирі дані DMV і Query Store тут не зберігаються.

| Таблиця | Колонки (тип) |
|---|---|
| `Advisor.AnalysisRun` | `RunId UNIQUEIDENTIFIER PK`, `Module VARCHAR(20)`, `RequestedServer NVARCHAR(256)`, `StartedAtUtc DATETIME2(3)`, `FinishedAtUtc DATETIME2(3) NULL`, `StartedBy NVARCHAR(256)`, `HostName NVARCHAR(256)`, `ToolVersion VARCHAR(32)`, `ParametersJson NVARCHAR(MAX)`, `FromArchive NVARCHAR(1024) NULL`, `ArchivePath NVARCHAR(1024) NULL`, `NamesMasked BIT`, `UnsafeFlags NVARCHAR(400) NULL`, `DatasetsJson NVARCHAR(MAX)`, `Provider NVARCHAR(100) NULL`, `Model NVARCHAR(200) NULL`, `InputTokens BIGINT`, `OutputTokens BIGINT`, `CostUsd DECIMAL(19,6)`, `Status VARCHAR(20)`, `ExitCode INT`, `WarningsJson NVARCHAR(MAX) NULL` |
| `Advisor.RunDataPeriod` | `RunDataPeriodId BIGINT IDENTITY PK`, `RunId FK CASCADE`, `ServerName NVARCHAR(256)`, `DatabaseName NVARCHAR(128) NULL`, `SqlServerStartTimeUtc DATETIME2(3)`, `LastFailoverUtc DATETIME2(3) NULL`, `StatsFromUtc DATETIME2(3)`, `StatsToUtc DATETIME2(3)`, `UptimeDays DECIMAL(9,2)`, `QueryStoreFromUtc DATETIME2(3) NULL`, `QueryStoreToUtc DATETIME2(3) NULL`, `QueryStoreDays DECIMAL(9,2) NULL`, `MinRequiredDays INT`, `IsSufficient BIT` |
| `Advisor.LlmCall` | `LlmCallId UNIQUEIDENTIFIER PK`, `RunId FK CASCADE`, `Purpose VARCHAR(20)`, `Provider NVARCHAR(100)`, `Model NVARCHAR(200)`, `PromptTemplateId VARCHAR(100) NULL`, `PromptTemplateVersion INT NULL`, `InputTokens INT`, `OutputTokens INT`, `CostUsd DECIMAL(19,6)`, `DurationMs INT`, `Success BIT`, `CreatedAtUtc DATETIME2(3)` |
| `Advisor.ToolRequest` | `ToolRequestId UNIQUEIDENTIFIER PK`, `RunId FK CASCADE`, `LlmCallId UNIQUEIDENTIFIER NULL`, `ToolName NVARCHAR(128)`, `ServerName NVARCHAR(256) NULL`, `DatabaseName NVARCHAR(128) NULL`, `ArgumentsJson NVARCHAR(MAX)`, `Decision VARCHAR(20)`, `RowCount INT NULL`, `Truncated BIT NULL`, `Success BIT NULL`, `ExecutedAtUtc DATETIME2(3) NULL` |
| `Advisor.Recommendation` | `RecommendationId UNIQUEIDENTIFIER PK`, `RunId FK CASCADE`, `Module VARCHAR(20)`, `Action VARCHAR(30)`, `Source VARCHAR(10)`, `ObjectKey NVARCHAR(850)`, `ServerName NVARCHAR(256)`, `DatabaseName NVARCHAR(128)`, `SchemaName NVARCHAR(128)`, `TableName NVARCHAR(128)`, `IndexName NVARCHAR(128) NULL`, `Title NVARCHAR(400)`, `Rationale NVARCHAR(MAX)`, `RiskLevel VARCHAR(10)`, `RiskDescription NVARCHAR(MAX)`, `ExecuteScript NVARCHAR(MAX)`, `RollbackScript NVARCHAR(MAX)`, `ValidationStatus VARCHAR(20)`, `ValidationJson NVARCHAR(MAX)`, `DropEligibilityJson NVARCHAR(MAX) NULL`, `IsDropEligible BIT NULL`, `RulesProfile VARCHAR(10) NULL`, `CrossCheckJson NVARCHAR(MAX) NULL`, `Provider NVARCHAR(100) NULL`, `Model NVARCHAR(200) NULL`, `PromptTemplateId VARCHAR(100) NULL`, `PromptTemplateVersion INT NULL`, `PeriodFromUtc DATETIME2(3) NULL`, `PeriodToUtc DATETIME2(3) NULL`, `UptimeDays DECIMAL(9,2) NULL`, `WarningsJson NVARCHAR(MAX) NULL`, `RecommendationJson NVARCHAR(MAX)`, `CreatedAtUtc DATETIME2(3)`; індекс `(ObjectKey, CreatedAtUtc)` |
| `Advisor.ObjectVerdict` | `RunId FK CASCADE`, `ObjectKey NVARCHAR(850)`, `Module VARCHAR(20)`, `AnalyzedAtUtc DATETIME2(3)`, `Verdict VARCHAR(20)`, `CountsTowardSeries BIT`, `PeriodDays DECIMAL(9,2)`, `RulesProfile VARCHAR(10) NULL`; PK `(RunId, ObjectKey)`; індекс `(ObjectKey, AnalyzedAtUtc)` |

Токени й вартість: `AnalysisRun` (сума) і `LlmCall` (кожен запит); рекомендація посилається на запуск і модель.

## 9. Формат звітів

Спільне для MD і HTML (по кожному запуску): заголовок (сервер, топологія, runId, час, хто запустив); **період даних** (таблиця DataPeriod; попередження, якщо недостатній); **зібрані набори даних** і попередження про вимкнені; маскування; активні unsafe-прапорці (виділено); модель, токени, вартість, дозапити моделі з рішеннями користувача; знахідки rules engine; рекомендації (порядок: Passed → Warning; CreateIndex, AlterIndex, DropIndex, партиціонування); розділ «Відхилені перевіркою».

Кожна рекомендація: заголовок `NNN. <Action> <schema.table>.<index>`; ризик (рівень і опис); обґрунтування; вплив; період даних; результати перевірки 4.8; для DropIndex — таблиця умов 4.4 (виконано / не виконано / невідомо), профіль правил (стандартний або пом'якшений з причиною), «на скількох аналізах ґрунтується і скільки підтверджень бракує»; cross-check; попередження; скрипт виконання і скрипт відкату (```sql).

SQL-файли: заголовок-коментар (рекомендація, сервер, база, runId, дата, ризик, попередження, умови 4.4). Скрипт DropIndex, для якого `isEligible = $false`, записується з закоментованими інструкціями й поясненням, яких умов бракує. Скрипти виконання й відкату — окремі файли.

## 10. Скрипт штатного логіна (`sql/Setup-IndexAdvisorLogin.sql`)

sqlcmd-змінні: `$(Mode)` = `Install|AddDatabase|Remove|Verify`, `$(LoginName)` (за замовчуванням `index-advisor`), `$(LoginType)` = `Sql|Windows`, `$(LoginPassword)` (лише для `Install` SQL-логіна; передає обгортка), `$(Databases)` (через кому або `ALL` — усі користувацькі бази ONLINE). Ідемпотентний.
- Серверна роль `srv_index_advisor`: `VIEW SERVER STATE`, `VIEW ANY DEFINITION`; логін — її член.
- У кожній базі: користувач = ім'я логіна, роль `db_index_advisor` (`IF USER_ID('db_index_advisor') IS NULL CREATE ROLE [db_index_advisor];`) з `VIEW DATABASE STATE`, `VIEW DEFINITION`; користувач — член ролі.
- Жодних прямих GRANT логіну чи користувачу, жодного членства в `db_datareader`, `db_owner`, `sysadmin` тощо, без SELECT на користувацькі таблиці. SQL-логін — `CHECK_POLICY = ON`.
- `Remove` — повне видалення (члени ролей, користувачі, ролі, логін, серверна роль). `Verify` — лише SELECT: фактичні права й членство логіна, попередження про зайві.
- Обгортка `Install-IaServiceLogin`: генерує пароль, що відповідає політиці складності, одразу `Set-Secret` у SecretManagement (ім'я секрету — як у `connection.passwordRef`), передає скрипту через sqlcmd-змінну, ніколи не виводить і не логує пароль; виконує для кожного з `-SqlInstance`.

## 11. Коди повернення і помилок

Коди процесу (`$script:IaExitCodes`): `0` Success; `1` SuccessWithWarnings (короткий період, частковий збір, рекомендації з `Failed`/`Warning`, неповні умови 4.4 не рахуються); `2` ConfigError; `3` ConnectionRefused (штатний логін, підключення); `4` CollectionFailed; `5` LlmFailed (зокрема бюджет); `6` RepositoryFailed; `9` Unexpected.
Коди помилок конверта (`$script:IaErrorCodes`): `ArgumentInvalid`, `CommandTooLong`, `NotSingleSelect`, `ForbiddenSource`, `UnknownParameter`, `MissingParameter`, `LoginRefused`, `ConnectionFailed`, `SqlError`, `Timeout`.
