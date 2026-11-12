-- Хеші запитів, що породили рекомендації відсутніх індексів поточної бази (sys.dm_db_missing_index_group_stats_query).
SELECT
	mig.index_handle AS indexHandle,
	CONVERT(VARCHAR(18), migsq.query_hash, 1) AS queryHash
FROM sys.dm_db_missing_index_group_stats_query AS migsq
INNER JOIN sys.dm_db_missing_index_groups AS mig ON mig.index_group_handle = migsq.group_handle
INNER JOIN sys.dm_db_missing_index_details AS mid ON mid.index_handle = mig.index_handle
WHERE mid.database_id = DB_ID()
ORDER BY mig.index_handle, queryHash;
