-- Відсутні індекси поточної бази: details, groups і group_stats (дата останнього seek у UTC).
SELECT
	mid.index_handle AS indexHandle,
	mig.index_group_handle AS groupHandle,
	mid.object_id AS objectId,
	OBJECT_SCHEMA_NAME(mid.object_id) AS schemaName,
	OBJECT_NAME(mid.object_id) AS tableName,
	mid.equality_columns AS equalityColumns,
	mid.inequality_columns AS inequalityColumns,
	mid.included_columns AS includedColumns,
	migs.user_seeks AS userSeeks,
	migs.user_scans AS userScans,
	CAST(migs.avg_total_user_cost AS FLOAT) AS avgTotalUserCost,
	CAST(migs.avg_user_impact AS FLOAT) AS avgUserImpact,
	DATEADD(MINUTE, DATEDIFF(MINUTE, SYSDATETIME(), SYSUTCDATETIME()), migs.last_user_seek) AS lastUserSeekUtc,
	migs.unique_compiles AS uniqueCompiles
FROM sys.dm_db_missing_index_details AS mid
INNER JOIN sys.dm_db_missing_index_groups AS mig ON mig.index_handle = mid.index_handle
INNER JOIN sys.dm_db_missing_index_group_stats AS migs ON migs.group_handle = mig.index_group_handle
WHERE mid.database_id = DB_ID()
ORDER BY mid.index_handle;
