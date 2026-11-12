-- Індекси: тип, унікальність, фільтр, fill factor, компресія (MIN/MAX по секціях), простір даних, дата статистики (UTC).
SELECT
	i.object_id AS objectId,
	i.index_id AS indexId,
	i.name AS indexName,
	i.type_desc AS typeDesc,
	i.is_primary_key AS isPrimaryKey,
	i.is_unique AS isUnique,
	i.is_unique_constraint AS isUniqueConstraint,
	i.is_disabled AS isDisabled,
	i.is_hypothetical AS isHypothetical,
	i.has_filter AS hasFilter,
	i.filter_definition AS filterDefinition,
	CAST(i.fill_factor AS INT) AS indexFillFactor,
	i.is_padded AS isPadded,
	i.allow_row_locks AS allowRowLocks,
	i.allow_page_locks AS allowPageLocks,
	i.ignore_dup_key AS ignoreDupKey,
	ds.name AS dataSpaceName,
	ds.type_desc AS dataSpaceType,
	pf.name AS partitionFunction,
	cmp.compressionMin,
	cmp.compressionMax,
	DATEADD(MINUTE, DATEDIFF(MINUTE, SYSDATETIME(), SYSUTCDATETIME()), STATS_DATE(i.object_id, i.index_id)) AS statsLastUpdatedUtc
FROM sys.indexes AS i
INNER JOIN sys.objects AS o ON o.object_id = i.object_id
LEFT JOIN sys.data_spaces AS ds ON ds.data_space_id = i.data_space_id
LEFT JOIN sys.partition_schemes AS psch ON psch.data_space_id = i.data_space_id
LEFT JOIN sys.partition_functions AS pf ON pf.function_id = psch.function_id
OUTER APPLY (
	SELECT
		MIN(p.data_compression_desc) AS compressionMin,
		MAX(p.data_compression_desc) AS compressionMax
	FROM sys.partitions AS p
	WHERE p.object_id = i.object_id
		AND p.index_id = i.index_id
) AS cmp
WHERE o.is_ms_shipped = 0
	AND o.type IN ('U', 'V')
ORDER BY i.object_id, i.index_id;
