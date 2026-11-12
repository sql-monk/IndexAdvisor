-- Таблиці та індексовані представлення бази зі схемою секціонування, ознаками реплікації та In-Memory OLTP.
SELECT
	o.object_id AS objectId,
	s.name AS schemaName,
	o.name AS tableName,
	CASE WHEN o.type = 'U' THEN 'USER_TABLE' ELSE 'VIEW' END AS objectType,
	CAST(CASE WHEN psch.data_space_id IS NULL THEN 0 ELSE 1 END AS BIT) AS isPartitioned,
	psch.name AS partitionScheme,
	pf.name AS partitionFunction,
	pf.boundary_value_on_right AS partitionRangeRight,
	pcol.name AS partitionColumn,
	CAST(CASE WHEN t.is_replicated = 1 OR t.is_merge_published = 1 OR t.is_sync_tran_subscribed = 1 THEN 1 ELSE 0 END AS BIT) AS isReplicated,
	CAST(ISNULL(t.is_memory_optimized, 0) AS BIT) AS isMemoryOptimized
FROM sys.objects AS o
INNER JOIN sys.schemas AS s ON s.schema_id = o.schema_id
LEFT JOIN sys.indexes AS i ON i.object_id = o.object_id AND i.index_id <= 1
LEFT JOIN sys.tables AS t ON t.object_id = o.object_id
LEFT JOIN sys.partition_schemes AS psch ON psch.data_space_id = i.data_space_id
LEFT JOIN sys.partition_functions AS pf ON pf.function_id = psch.function_id
LEFT JOIN sys.index_columns AS pic ON pic.object_id = i.object_id AND pic.index_id = i.index_id AND pic.partition_ordinal = 1
LEFT JOIN sys.columns AS pcol ON pcol.object_id = pic.object_id AND pcol.column_id = pic.column_id
WHERE o.is_ms_shipped = 0
	AND (o.type = 'U' OR (o.type = 'V' AND i.index_id = 1))
ORDER BY o.object_id;
