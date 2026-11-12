# index_usage_stats

## Description
Статистика використання індексів таблиці з sys.dm_db_index_usage_stats на поточній репліці: seeks, scans, lookups, updates
(користувацькі й системні) та дати останнього використання (UTC). Індекси без записів у DMV повертаються з нулями.
sqlserverStartTimeUtc — час запуску інстансу, з якого накопичується статистика (DMV обнуляються після перезапуску).

## Method
Query

## Server

## Database

## Parameters
- @SchemaName: string {maxLength=128} - Схема таблиці
- @TableName: string {maxLength=128} - Ім'я таблиці або індексованого представлення
- @MinUpdates: int? {min=0, max=2147483647, default=0} - Мінімум user updates

## Query
```sql
SELECT
	s.name AS schemaName,
	o.name AS tableName,
	i.index_id AS indexId,
	i.name AS indexName,
	i.type_desc AS indexType,
	i.is_primary_key AS isPrimaryKey,
	i.is_unique AS isUnique,
	ISNULL(us.user_seeks, 0) AS userSeeks,
	ISNULL(us.user_scans, 0) AS userScans,
	ISNULL(us.user_lookups, 0) AS userLookups,
	ISNULL(us.user_updates, 0) AS userUpdates,
	DATEADD(MINUTE, DATEDIFF(MINUTE, SYSDATETIME(), SYSUTCDATETIME()), us.last_user_seek) AS lastUserSeekUtc,
	DATEADD(MINUTE, DATEDIFF(MINUTE, SYSDATETIME(), SYSUTCDATETIME()), us.last_user_scan) AS lastUserScanUtc,
	DATEADD(MINUTE, DATEDIFF(MINUTE, SYSDATETIME(), SYSUTCDATETIME()), us.last_user_lookup) AS lastUserLookupUtc,
	DATEADD(MINUTE, DATEDIFF(MINUTE, SYSDATETIME(), SYSUTCDATETIME()), us.last_user_update) AS lastUserUpdateUtc,
	ISNULL(us.system_seeks, 0) AS systemSeeks,
	ISNULL(us.system_scans, 0) AS systemScans,
	ISNULL(us.system_lookups, 0) AS systemLookups,
	ISNULL(us.system_updates, 0) AS systemUpdates,
	DATEADD(MINUTE, DATEDIFF(MINUTE, SYSDATETIME(), SYSUTCDATETIME()), osi.sqlserver_start_time) AS sqlserverStartTimeUtc
FROM sys.objects AS o
INNER JOIN sys.schemas AS s
	ON s.schema_id = o.schema_id
INNER JOIN sys.indexes AS i
	ON i.object_id = o.object_id
LEFT JOIN sys.dm_db_index_usage_stats AS us
	ON us.database_id = DB_ID()
	AND us.object_id = i.object_id
	AND us.index_id = i.index_id
CROSS JOIN sys.dm_os_sys_info AS osi
WHERE o.type IN ('U', 'V')
	AND s.name = @SchemaName
	AND o.name = @TableName
	AND ISNULL(us.user_updates, 0) >= @MinUpdates
ORDER BY i.index_id;
```
