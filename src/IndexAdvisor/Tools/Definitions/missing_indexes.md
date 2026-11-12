# missing_indexes

## Description
Пропозиції відсутніх індексів поточної бази з sys.dm_db_missing_index_details, groups і group_stats: equality, inequality та
included-колонки, кількість seeks і scans, середня вартість і очікуваний вплив, оцінка вигоди
(estimatedImprovement = avgTotalUserCost * avgUserImpact * (userSeeks + userScans)), дати останнього використання (UTC).
Дані DMV обнуляються після перезапуску інстансу. Сортування — за оцінкою вигоди.

## Method
Query

## Server

## Database

## Parameters
- @SchemaName: string? {maxLength=128} - Схема таблиці (порожньо — усі схеми)
- @TableName: string? {maxLength=128} - Ім'я таблиці (порожньо — усі таблиці)
- @MinImpact: decimal? {min=0, max=100, default=0} - Мінімальний очікуваний вплив avgUserImpact, %

## Query
```sql
SELECT
	OBJECT_SCHEMA_NAME(d.object_id, d.database_id) AS schemaName,
	OBJECT_NAME(d.object_id, d.database_id) AS tableName,
	d.index_handle AS indexHandle,
	d.equality_columns AS equalityColumns,
	d.inequality_columns AS inequalityColumns,
	d.included_columns AS includedColumns,
	gs.unique_compiles AS uniqueCompiles,
	gs.user_seeks AS userSeeks,
	gs.user_scans AS userScans,
	gs.avg_total_user_cost AS avgTotalUserCost,
	gs.avg_user_impact AS avgUserImpact,
	gs.avg_total_user_cost * gs.avg_user_impact * (gs.user_seeks + gs.user_scans) AS estimatedImprovement,
	DATEADD(MINUTE, DATEDIFF(MINUTE, SYSDATETIME(), SYSUTCDATETIME()), gs.last_user_seek) AS lastUserSeekUtc,
	DATEADD(MINUTE, DATEDIFF(MINUTE, SYSDATETIME(), SYSUTCDATETIME()), gs.last_user_scan) AS lastUserScanUtc
FROM sys.dm_db_missing_index_details AS d
INNER JOIN sys.dm_db_missing_index_groups AS g
	ON g.index_handle = d.index_handle
INNER JOIN sys.dm_db_missing_index_group_stats AS gs
	ON gs.group_handle = g.index_group_handle
WHERE d.database_id = DB_ID()
	AND (@SchemaName IS NULL OR OBJECT_SCHEMA_NAME(d.object_id, d.database_id) = @SchemaName)
	AND (@TableName IS NULL OR OBJECT_NAME(d.object_id, d.database_id) = @TableName)
	AND gs.avg_user_impact >= @MinImpact
ORDER BY gs.avg_total_user_cost * gs.avg_user_impact * (gs.user_seeks + gs.user_scans) DESC, d.index_handle;
```
