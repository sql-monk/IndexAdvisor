-- Використання індексів поточної бази з sys.dm_db_index_usage_stats (дати в UTC).
SELECT
	us.object_id AS objectId,
	us.index_id AS indexId,
	us.user_seeks AS userSeeks,
	us.user_scans AS userScans,
	us.user_lookups AS userLookups,
	us.user_updates AS userUpdates,
	DATEADD(MINUTE, DATEDIFF(MINUTE, SYSDATETIME(), SYSUTCDATETIME()), us.last_user_seek) AS lastUserSeekUtc,
	DATEADD(MINUTE, DATEDIFF(MINUTE, SYSDATETIME(), SYSUTCDATETIME()), us.last_user_scan) AS lastUserScanUtc,
	DATEADD(MINUTE, DATEDIFF(MINUTE, SYSDATETIME(), SYSUTCDATETIME()), us.last_user_lookup) AS lastUserLookupUtc,
	DATEADD(MINUTE, DATEDIFF(MINUTE, SYSDATETIME(), SYSUTCDATETIME()), us.last_user_update) AS lastUserUpdateUtc
FROM sys.dm_db_index_usage_stats AS us
WHERE us.database_id = DB_ID()
ORDER BY us.object_id, us.index_id;
