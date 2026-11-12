# Схема YAML-конфігурації IndexAdvisor. Власник — оркестратор (контракт).
# Вузол: Name, Type (object|string|int|number|bool|array|map), Default, Description,
# необов'язково: Enum, Min, Max, Required, Items (тип елемента масиву: рядок-тип або вузол object),
# Properties (для object), Values (вузол-значення для map), Example (приклад для шаблону map), Secret (посилання на секрет).
# Формат посилання на секрет (SecretRef): 'env:ІМ'Я_ЗМІННОЇ' | 'secret:ІмяСекрету' | 'secret:Сховище/ІмяСекрету'.
@{
	Name = 'root'
	Type = 'object'
	Description = 'Конфігурація запуску IndexAdvisor'
	Properties = @(
		@{ Name = 'version'; Type = 'int'; Default = 1; Min = 1; Max = 1; Required = $true; Description = 'Версія формату конфігурації' }
		@{ Name = 'servers'; Type = 'array'; Items = 'string'; Default = @(); Description = 'Імена інстансів або listener AG. Кожен сервер аналізується окремим запуском (run)' }
		@{ Name = 'module'; Type = 'string'; Enum = @('Indexes', 'Partitioning', 'Both'); Default = 'Indexes'; Description = 'Модуль аналізу: індекси, партиціонування або обидва' }
		@{
			Name = 'scope'
			Type = 'object'
			Description = 'Включення та виключення об''єктів. Порожній include означає все. Підтримуються шаблони * і ?'
			Properties = @(
				@{
					Name = 'databases'; Type = 'object'; Description = 'Бази даних'
					Properties = @(
						@{ Name = 'include'; Type = 'array'; Items = 'string'; Default = @(); Description = 'Бази для аналізу' }
						@{ Name = 'exclude'; Type = 'array'; Items = 'string'; Default = @(); Description = 'Бази, які пропускаються' }
					)
				}
				@{
					Name = 'schemas'; Type = 'object'; Description = 'Схеми'
					Properties = @(
						@{ Name = 'include'; Type = 'array'; Items = 'string'; Default = @(); Description = 'Схеми для аналізу' }
						@{ Name = 'exclude'; Type = 'array'; Items = 'string'; Default = @(); Description = 'Схеми, які пропускаються' }
					)
				}
				@{
					Name = 'tables'; Type = 'object'; Description = 'Таблиці у форматі schema.table'
					Properties = @(
						@{ Name = 'include'; Type = 'array'; Items = 'string'; Default = @(); Description = 'Таблиці для аналізу' }
						@{ Name = 'exclude'; Type = 'array'; Items = 'string'; Default = @(); Description = 'Таблиці, які пропускаються' }
					)
				}
			)
		}
		@{
			Name = 'analysisWindow'
			Type = 'object'
			Description = 'Вікно аналізу Query Store'
			Properties = @(
				@{ Name = 'days'; Type = 'int'; Default = 30; Min = 1; Max = 3650; Description = 'Тривалість вікна в днях' }
				@{ Name = 'monthStartRule'; Type = 'bool'; Default = $true; Description = 'На початку місяця вікном береться весь попередній місяць (розділ 4.4)' }
				@{ Name = 'monthStartDays'; Type = 'int'; Default = 5; Min = 1; Max = 15; Description = 'Скільки перших днів місяця вважаються його початком' }
			)
		}
		@{
			Name = 'connection'
			Type = 'object'
			Description = 'Підключення до цільових серверів'
			Properties = @(
				@{ Name = 'authentication'; Type = 'string'; Enum = @('Sql', 'Windows'); Default = 'Sql'; Description = 'Sql — SQL-логін, Windows — поточний обліковий запис Windows' }
				@{ Name = 'login'; Type = 'string'; Default = 'index-advisor'; Description = 'Логін для SQL-автентифікації' }
				@{ Name = 'passwordRef'; Type = 'string'; Secret = $true; Default = 'secret:IndexAdvisor-index-advisor'; Description = 'Посилання на пароль у захищеному сховищі або змінній середовища (не сам пароль)' }
				@{ Name = 'encrypt'; Type = 'string'; Enum = @('Mandatory', 'Optional', 'Strict'); Default = 'Mandatory'; Description = 'Параметр Encrypt рядка підключення' }
				@{ Name = 'trustServerCertificate'; Type = 'bool'; Default = $false; Description = 'Параметр TrustServerCertificate' }
				@{ Name = 'applicationName'; Type = 'string'; Default = 'IndexAdvisor'; Description = 'Application Name у рядку підключення' }
				@{ Name = 'connectTimeoutSeconds'; Type = 'int'; Default = 15; Min = 1; Max = 300; Description = 'Таймаут підключення, с' }
				@{ Name = 'commandTimeoutSeconds'; Type = 'int'; Default = 30; Min = 1; Max = 3600; Description = 'Таймаут виконання команди, с' }
				@{ Name = 'lockTimeoutMs'; Type = 'int'; Default = 1000; Min = 0; Max = 600000; Description = 'SET LOCK_TIMEOUT, мс' }
			)
		}
		@{
			Name = 'security'
			Type = 'object'
			Description = 'Політика облікового запису'
			Properties = @(
				@{ Name = 'standardLogin'; Type = 'string'; Default = 'index-advisor'; Description = 'Ім''я штатного логіна, створеного скриптом підготовки (SQL-логін або DOMAIN\user)' }
			)
		}
		@{
			Name = 'limits'
			Type = 'object'
			Description = 'Ліміти конвеєра виконання та аналізу'
			Properties = @(
				@{ Name = 'defaultFetch'; Type = 'int'; Default = 300; Min = 1; Max = 5000; Description = 'Кількість рядків за замовчуванням' }
				@{ Name = 'maxRows'; Type = 'int'; Default = 5000; Min = 1; Max = 5000; Description = 'Жорстка межа кількості рядків' }
				@{ Name = 'largeResultWarningRows'; Type = 'int'; Default = 1000; Min = 1; Max = 5000; Description = 'Поріг попередження про великий обсяг контексту' }
				@{ Name = 'maxCommandLength'; Type = 'int'; Default = 10000; Min = 100; Max = 1000000; Description = 'Максимальна довжина тексту команди, символів' }
				@{ Name = 'maxToolRequestsPerAnalysis'; Type = 'int'; Default = 10; Min = 0; Max = 100; Description = 'Ліміт дозапитів моделі на один аналіз' }
				@{ Name = 'maxTokensPerAnalysis'; Type = 'int'; Default = 200000; Min = 1000; Max = 10000000; Description = 'Ліміт токенів (вхід + вихід) на один аналіз' }
			)
		}
		@{
			Name = 'collector'
			Type = 'object'
			Description = 'Збір даних'
			Properties = @(
				@{
					Name = 'datasets'; Type = 'object'; Description = 'Набори даних (розділ 4.1). indexStructure і instanceStartTime обов''язкові й не вимикаються'
					Properties = @(
						@{ Name = 'indexStructure'; Type = 'bool'; Default = $true; Description = 'Структура індексів (обов''язковий)' }
						@{ Name = 'instanceStartTime'; Type = 'bool'; Default = $true; Description = 'Час запуску інстансу (обов''язковий)' }
						@{ Name = 'usageStats'; Type = 'bool'; Default = $true; Description = 'sys.dm_db_index_usage_stats' }
						@{ Name = 'operationalStats'; Type = 'bool'; Default = $true; Description = 'sys.dm_db_index_operational_stats' }
						@{ Name = 'sizeAndFragmentation'; Type = 'bool'; Default = $true; Description = 'sys.dm_db_partition_stats, sys.dm_db_index_physical_stats (LIMITED)' }
						@{ Name = 'missingIndexes'; Type = 'bool'; Default = $true; Description = 'sys.dm_db_missing_index_*' }
						@{ Name = 'queryStore'; Type = 'bool'; Default = $true; Description = 'Query Store: топ-запити і плани' }
						@{ Name = 'constraintsAndReplication'; Type = 'bool'; Default = $true; Description = 'PK, UNIQUE, FK, реплікація, хінти, роль репліки AG' }
					)
				}
				@{ Name = 'physicalStatsTimeBudgetSeconds'; Type = 'int'; Default = 300; Min = 1; Max = 86400; Description = 'Сумарний ліміт часу на sys.dm_db_index_physical_stats на одну базу, с' }
				@{ Name = 'queryStorePlansTimeBudgetSeconds'; Type = 'int'; Default = 900; Min = 10; Max = 86400; Description = 'Ліміт часу на збір планів Query Store на одну базу, с (вичерпано — використання індексів у планах невідоме)' }
				@{ Name = 'queryStoreTopN'; Type = 'int'; Default = 50; Min = 1; Max = 1000; Description = 'Кількість топ-запитів Query Store за кожним критерієм' }
				@{ Name = 'queryStoreMinFreeSpacePercent'; Type = 'int'; Default = 10; Min = 0; Max = 100; Description = 'Попередження, якщо вільного місця Query Store менше' }
			)
		}
		@{
			Name = 'archive'
			Type = 'object'
			Description = 'Локальний ZIP-архів зібраних даних і промпту'
			Properties = @(
				@{ Name = 'enabled'; Type = 'bool'; Default = $true; Description = 'Зберігати архів' }
				@{ Name = 'path'; Type = 'string'; Default = './archive'; Description = 'Каталог архівів' }
				@{ Name = 'retentionDays'; Type = 'int'; Default = 90; Min = 1; Max = 3650; Description = 'Термін зберігання архівів, днів' }
				@{ Name = 'restrictAcl'; Type = 'bool'; Default = $true; Description = 'Обмежити доступ до нового каталогу правами NTFS: лише поточний користувач, SYSTEM і Administrators, без успадкування (Windows). Права наявного каталогу не змінюються — лише попередження, якщо він успадковує права' }
			)
		}
		@{
			Name = 'logging'
			Type = 'object'
			Description = 'Markdown-журнал викликів'
			Properties = @(
				@{ Name = 'path'; Type = 'string'; Default = './logs'; Description = 'Каталог журналів (один файл на сесію)' }
			)
		}
		@{
			Name = 'output'
			Type = 'object'
			Description = 'Результати'
			Properties = @(
				@{ Name = 'path'; Type = 'string'; Default = './out'; Description = 'Каталог результатів' }
				@{ Name = 'formats'; Type = 'array'; Items = 'string'; Enum = @('Markdown', 'Sql', 'Html', 'Json', 'Console'); Default = @('Markdown', 'Sql', 'Console'); Description = 'Формати результату' }
				@{ Name = 'htmlTheme'; Type = 'string'; Enum = @('Auto', 'Light', 'Dark'); Default = 'Auto'; Description = 'Тема report.html: Auto — як у браузері чи ОС, Light/Dark — примусово' }
			)
		}
		@{
			Name = 'repository'
			Type = 'object'
			Description = 'База-репозиторій історії рекомендацій (IndexAdvisor)'
			Properties = @(
				@{ Name = 'enabled'; Type = 'bool'; Default = $true; Description = 'Записувати результати в репозиторій (false — разовий аналіз)' }
				@{ Name = 'server'; Type = 'string'; Default = ''; Description = 'Сервер репозиторію' }
				@{ Name = 'database'; Type = 'string'; Default = 'IndexAdvisor'; Description = 'База репозиторію' }
				@{ Name = 'authentication'; Type = 'string'; Enum = @('Windows', 'Sql'); Default = 'Windows'; Description = 'Автентифікація до репозиторію' }
				@{ Name = 'login'; Type = 'string'; Default = ''; Description = 'Логін для SQL-автентифікації' }
				@{ Name = 'passwordRef'; Type = 'string'; Secret = $true; Default = ''; Description = 'Посилання на пароль у захищеному сховищі або змінній середовища (не сам пароль)' }
				@{ Name = 'encrypt'; Type = 'string'; Enum = @('Mandatory', 'Optional', 'Strict'); Default = 'Mandatory'; Description = 'Параметр Encrypt' }
				@{ Name = 'trustServerCertificate'; Type = 'bool'; Default = $false; Description = 'Параметр TrustServerCertificate' }
				@{ Name = 'historyRetentionDays'; Type = 'int'; Default = 730; Min = 30; Max = 36500; Description = 'Термін зберігання історії рекомендацій, днів' }
			)
		}
		@{
			Name = 'rules'
			Type = 'object'
			Description = 'Rules engine і правила видалення (розділи 4.3, 4.4)'
			Properties = @(
				@{
					Name = 'drop'; Type = 'object'; Description = 'Стандартні правила видалення'
					Properties = @(
						@{ Name = 'requiredConsecutive'; Type = 'int'; Default = 3; Min = 1; Max = 100; Description = 'N аналізів поспіль з рекомендацією видалення' }
						@{ Name = 'minIntervalDays'; Type = 'int'; Default = 7; Min = 1; Max = 365; Description = 'Мінімальний інтервал між аналізами серії, днів' }
						@{ Name = 'minUptimeDays'; Type = 'int'; Default = 14; Min = 14; Max = 3650; Description = 'Мінімальний період даних, днів (не менше 14), за якого аналіз зараховується до серії рекомендацій на видалення. Період рахується від запуску інстансу чи failover, для індексу — від останньої перебудови, якщо вона пізніша. Коротший період аналіз не блокує: запуск не зараховується до серії, а короткий період інстансу чи бази дає попередження (код повернення 1). З цим порогом порівнюються також термін зберігання й період даних Query Store' }
					)
				}
				@{
					Name = 'relaxed'; Type = 'object'; Description = 'Пом''якшені правила для «дорогих» індексів'
					Properties = @(
						@{ Name = 'enabled'; Type = 'bool'; Default = $true; Description = 'Застосовувати пом''якшені правила' }
						@{ Name = 'requiredConsecutive'; Type = 'int'; Default = 1; Min = 1; Max = 100; Description = 'N для «дорогих» індексів' }
						@{ Name = 'minUptimeDays'; Type = 'int'; Default = 7; Min = 1; Max = 3650; Description = 'Мінімальний період даних для «дорогих» індексів, днів (діє менше з цього значення і стандартного)' }
						@{ Name = 'minWriteToReadRatio'; Type = 'number'; Default = 10; Min = 1; Max = 1000000; Description = 'updates / (seeks + scans + lookups), з якого запис «значно переважає»' }
						@{ Name = 'maxReads'; Type = 'int'; Default = 1000; Min = 0; Max = 2147483647; Description = 'Читань (seeks + scans + lookups) не більше — «читань мало»' }
						@{ Name = 'minLockWaitMs'; Type = 'int'; Default = 60000; Min = 0; Max = 2147483647; Description = 'row_lock_wait_in_ms + page_lock_wait_in_ms, з якого очікування помітні' }
						@{ Name = 'minLatchWaitMs'; Type = 'int'; Default = 60000; Min = 0; Max = 2147483647; Description = 'page_latch_wait_in_ms + page_io_latch_wait_in_ms, з якого очікування помітні' }
					)
				}
				@{
					Name = 'observationOverrides'; Type = 'array'; Default = @(); Description = 'Період спостереження окремо для сервера, бази чи таблиці (найточніший збіг перемагає)'
					Items = @{
						Name = 'override'; Type = 'object'; Description = 'Перевизначення'
						Properties = @(
							@{ Name = 'server'; Type = 'string'; Required = $true; Description = 'Сервер (або ім''я AG)' }
							@{ Name = 'database'; Type = 'string'; Default = ''; Description = 'База (порожньо — весь сервер)' }
							@{ Name = 'table'; Type = 'string'; Default = ''; Description = 'Таблиця schema.table (порожньо — вся база)' }
							@{ Name = 'minUptimeDays'; Type = 'int'; Required = $true; Min = 14; Max = 3650; Description = 'Мінімальний період даних, днів (замість rules.drop.minUptimeDays)' }
						)
					}
				}
				@{ Name = 'maxIndexesPerTable'; Type = 'int'; Default = 10; Min = 1; Max = 1000; Description = 'Поріг «надмірної кількості індексів» на таблиці' }
				@{ Name = 'writeOnlyMinUpdates'; Type = 'int'; Default = 1000; Min = 0; Max = 2147483647; Description = 'Мінімум updates для «write-only» індексу без читань' }
				@{
					Name = 'fragmentation'; Type = 'object'; Description = 'Пороги фрагментації'
					Properties = @(
						@{ Name = 'minPageCount'; Type = 'int'; Default = 1000; Min = 0; Max = 2147483647; Description = 'Ігнорувати менші індекси' }
						@{ Name = 'reorganizePercent'; Type = 'number'; Default = 10; Min = 0; Max = 100; Description = 'Поріг REORGANIZE, %' }
						@{ Name = 'rebuildPercent'; Type = 'number'; Default = 30; Min = 0; Max = 100; Description = 'Поріг REBUILD, %' }
					)
				}
			)
		}
		@{
			Name = 'partitioning'
			Type = 'object'
			Description = 'Модуль рекомендацій щодо партиціонування (розділ 4.6)'
			Properties = @(
				@{ Name = 'minSizeGb'; Type = 'number'; Default = 50; Min = 0; Max = 1000000; Description = 'Мінімальний розмір таблиці-кандидата, ГБ. Кандидат має відповідати обом порогам — розміру й кількості рядків (0 вимикає поріг)' }
				@{ Name = 'minRowCount'; Type = 'int'; Default = 100000000; Min = 0; Max = 2147483647; Description = 'Мінімальна кількість рядків таблиці-кандидата. Діє разом із minSizeGb (0 вимикає поріг)' }
				@{ Name = 'minDateFilterShare'; Type = 'number'; Default = 0.6; Min = 0; Max = 1; Description = 'Частка запитів (за вартістю), що фільтрують за одним стовпцем дати чи періоду' }
				@{ Name = 'maxPartitionSkewRatio'; Type = 'number'; Default = 10; Min = 1; Max = 1000000; Description = 'Поріг перекосу: найбільша секція / медіана' }
				@{ Name = 'minFuturePartitions'; Type = 'int'; Default = 2; Min = 0; Max = 1000; Description = 'Скільки порожніх секцій на майбутні періоди має бути попереду' }
			)
		}
		@{
			Name = 'llm'
			Type = 'object'
			Description = 'LLM-аналіз і провайдери (розділ 5)'
			Properties = @(
				@{ Name = 'provider'; Type = 'string'; Default = ''; Description = 'Ім''я провайдера з llm.providers' }
				@{ Name = 'model'; Type = 'string'; Default = ''; Description = 'Перевизначення моделі провайдера (порожньо — модель із налаштувань провайдера)' }
				@{ Name = 'crossCheckProvider'; Type = 'string'; Default = ''; Description = 'Другий провайдер для cross-check критичних рекомендацій (порожньо — вимкнено)' }
				@{ Name = 'localOnly'; Type = 'bool'; Default = $false; Description = 'Режим «тільки локальна модель»' }
				@{ Name = 'maskNames'; Type = 'bool'; Default = $false; Description = 'Маскувати імена об''єктів перед відправкою в модель (літерали в текстах запитів очищуються завжди)' }
				@{ Name = 'autoApproveToolRequests'; Type = 'bool'; Default = $false; Description = 'Автопідтвердження дозапитів моделі' }
				@{ Name = 'budgetLedgerPath'; Type = 'string'; Default = './state/llm-usage.json'; Description = 'Локальний облік витрат для денного і місячного бюджету' }
				@{
					Name = 'providers'; Type = 'map'; Default = @{}; Description = 'Провайдери за іменами'
					Example = @{
						openai = @{ type = 'OpenAI'; model = 'gpt-4.1'; apiKeyRef = 'secret:IndexAdvisor-openai' }
						local = @{ type = 'OpenAICompatible'; endpoint = 'http://localhost:11434/v1'; model = 'qwen2.5-coder:32b'; isLocal = $true }
					}
					Values = @{
						Name = 'provider'; Type = 'object'; Description = 'Налаштування провайдера'
						Properties = @(
							@{ Name = 'type'; Type = 'string'; Required = $true; Enum = @('OpenAI', 'Anthropic', 'Cohere', 'AzureOpenAI', 'OpenAICompatible'); Description = 'Тип провайдера' }
							@{ Name = 'endpoint'; Type = 'string'; Default = ''; Description = 'Endpoint (порожньо — стандартний для типу; для AzureOpenAI і OpenAICompatible обов''язковий)' }
							@{ Name = 'model'; Type = 'string'; Required = $true; Description = 'Модель (для AzureOpenAI — ім''я розгортання)' }
							@{ Name = 'apiKeyRef'; Type = 'string'; Secret = $true; Default = ''; Description = 'Посилання на API-ключ у захищеному сховищі або змінній середовища (не сам ключ). Для OpenAICompatible можна не задавати' }
							@{ Name = 'apiVersion'; Type = 'string'; Default = ''; Description = 'Версія API (AzureOpenAI, Anthropic)' }
							@{ Name = 'isLocal'; Type = 'bool'; Default = $false; Description = 'Локальна модель (дозволена в режимі localOnly лише для типу OpenAICompatible)' }
							@{ Name = 'maxTokensPerRequest'; Type = 'int'; Default = 4096; Min = 1; Max = 1000000; Description = 'Ліміт вихідних токенів на запит' }
							@{ Name = 'maxContextTokens'; Type = 'int'; Default = 100000; Min = 1000; Max = 10000000; Description = 'Бюджет вхідного контексту для стиснення' }
							@{ Name = 'dailyBudgetUsd'; Type = 'number'; Default = 0; Min = 0; Max = 1000000; Description = 'Денний бюджет, USD (0 — без ліміту)' }
							@{ Name = 'monthlyBudgetUsd'; Type = 'number'; Default = 0; Min = 0; Max = 10000000; Description = 'Місячний бюджет, USD (0 — без ліміту)' }
							@{ Name = 'inputPricePer1MTokensUsd'; Type = 'number'; Default = 0; Min = 0; Max = 100000; Description = 'Ціна 1 млн вхідних токенів, USD' }
							@{ Name = 'outputPricePer1MTokensUsd'; Type = 'number'; Default = 0; Min = 0; Max = 100000; Description = 'Ціна 1 млн вихідних токенів, USD' }
							@{ Name = 'promptCaching'; Type = 'bool'; Default = $true; Description = 'Кешування промптів Anthropic: системний промпт і діалог (дозапити читають контекст з кешу; перший виклик — запис у кеш)' }
							@{ Name = 'cacheWritePricePer1MTokensUsd'; Type = 'number'; Default = 0; Min = 0; Max = 100000; Description = 'Ціна запису 1 млн токенів у кеш, USD (0 — 1,25 ціни входу)' }
							@{ Name = 'cacheReadPricePer1MTokensUsd'; Type = 'number'; Default = 0; Min = 0; Max = 100000; Description = 'Ціна читання 1 млн токенів з кешу, USD (0 — 0,1 ціни входу для Anthropic, 0,5 для інших)' }
							@{ Name = 'timeoutSeconds'; Type = 'int'; Default = 120; Min = 1; Max = 3600; Description = 'Таймаут HTTP-запиту, с' }
							@{ Name = 'retryCount'; Type = 'int'; Default = 3; Min = 0; Max = 10; Description = 'Кількість повторів' }
						)
					}
				}
			)
		}
		@{
			Name = 'tools'
			Type = 'object'
			Description = 'Декларативні інструменти для дозапитів моделі (розділ 4.7)'
			Properties = @(
				@{ Name = 'definitionsPath'; Type = 'string'; Default = ''; Description = 'Каталог Markdown-інструментів (порожньо — вбудовані)' }
				@{ Name = 'strict'; Type = 'bool'; Default = $true; Description = 'Невалідний файл зупиняє завантаження' }
			)
		}
		@{
			Name = 'unsafe'
			Type = 'object'
			Description = 'Небезпечні режими. Кожен вмикається явно, з попередженням і записом у журнал та в кожну рекомендацію'
			Properties = @(
				@{ Name = 'disableSelectCheck'; Type = 'bool'; Default = $false; Description = 'Вимкнути перевірку «рівно одна інструкція SELECT»' }
				@{ Name = 'disableMaxdop'; Type = 'bool'; Default = $false; Description = 'Не додавати OPTION (MAXDOP 1)' }
				@{ Name = 'disableTimeouts'; Type = 'bool'; Default = $false; Description = 'Вимкнути таймаут виконання команди' }
				@{ Name = 'allowFreeQuery'; Type = 'bool'; Default = $false; Description = 'Дозволити моделі вільний запит (перевірка SELECT і джерел діє далі)' }
				@{ Name = 'allowNonStandardLogin'; Type = 'bool'; Default = $false; Description = 'Дозволити підключення не під штатним логіном (з перевіркою фактичних прав)' }
			)
		}
		@{
			Name = 'maintenance'
			Type = 'object'
			Description = 'Скрипти обслуговування індексів через dbo.usp_AdaptiveIndexDefrag (Microsoft Tiger Toolbox) і завдання SQL Agent'
			Properties = @(
				@{ Name = 'enabled'; Type = 'bool'; Default = $false; Description = 'Формувати скрипти обслуговування в кожному запуску (maintenance/ у каталозі результатів)' }
				@{ Name = 'procedureDatabase'; Type = 'string'; Default = 'msdb'; Description = 'База, де встановлено usp_AdaptiveIndexDefrag і її таблиці' }
				@{ Name = 'jobName'; Type = 'string'; Default = 'IndexAdvisor - AdaptiveIndexDefrag'; Description = 'Назва завдання SQL Agent' }
				@{ Name = 'jobOwner'; Type = 'string'; Default = ''; Description = 'Власник завдання (порожньо — логін, що виконує скрипт)' }
				@{
					Name = 'scheduleDays'; Type = 'array'; Items = 'string'; Enum = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
					Default = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'); Description = 'Дні запуску завдання'
				}
				@{ Name = 'startTime'; Type = 'string'; Default = '01:00'; Description = 'Час запуску HH:mm (час сервера)' }
				@{ Name = 'timeLimitMinutes'; Type = 'int'; Default = 240; Min = 10; Max = 1440; Description = 'Ліміт часу на всі бази за один запуск, хв' }
				@{ Name = 'largeIndexMb'; Type = 'number'; Default = 20480; Min = 0; Max = 100000000; Description = 'Індекси, більші за цей розмір, обслуговуються лише в дні largeIndexDays (0 — без обмеження), МБ' }
				@{
					Name = 'largeIndexDays'; Type = 'array'; Items = 'string'; Enum = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
					Default = @('Saturday', 'Sunday'); Description = 'Дні обслуговування великих індексів'
				}
				@{ Name = 'columnstoreRebuildPercent'; Type = 'number'; Default = 10; Min = 0; Max = 100; Description = 'Поріг перебудови columnstore (частка видалених рядків), %' }
				@{ Name = 'resumableRebuild'; Type = 'bool'; Default = $true; Description = 'RESUMABLE = ON для онлайн-перебудови (Enterprise, SQL Server 2017+)' }
				@{ Name = 'sortInTempDb'; Type = 'bool'; Default = $true; Description = 'SORT_IN_TEMPDB = ON (не застосовується разом з RESUMABLE)' }
				@{ Name = 'maxDop'; Type = 'int'; Default = 0; Min = 0; Max = 64; Description = 'MAXDOP для перебудови й статистики (0 — налаштування сервера)' }
				@{ Name = 'updateStatistics'; Type = 'bool'; Default = $true; Description = 'Оновлювати статистику після REORGANIZE' }
				@{ Name = 'excludeDropCandidates'; Type = 'bool'; Default = $true; Description = 'Не обслуговувати індекси, які запуск рекомендує видалити' }
				@{ Name = 'purgeLogs'; Type = 'bool'; Default = $true; Description = 'Другий крок завдання: usp_AdaptiveIndexDefrag_PurgeLogs' }
			)
		}
		@{
			Name = 'run'
			Type = 'object'
			Description = 'Режим запуску'
			Properties = @(
				@{ Name = 'nonInteractive'; Type = 'bool'; Default = $false; Description = 'Неінтерактивний режим (SQL Agent, Rundeck, cron): дозапити без автопідтвердження відхиляються' }
			)
		}
	)
}
