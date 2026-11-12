-- Розмір і кількість рядків по секціях індексів; межа секції: для RANGE LEFT — верхня, для RANGE RIGHT — нижня.
SELECT
	ps.object_id AS objectId,
	ps.index_id AS indexId,
	ps.partition_number AS partitionNumber,
	ps.row_count AS partitionRows,
	CAST(ps.used_page_count * 8 / 1024.0 AS FLOAT) AS usedMb,
	CAST(ps.reserved_page_count * 8 / 1024.0 AS FLOAT) AS reservedMb,
	p.data_compression_desc AS compressionDesc,
	CASE
		WHEN prv.value IS NULL THEN NULL
		WHEN CAST(SQL_VARIANT_PROPERTY(prv.value, 'BaseType') AS SYSNAME) IN (N'date', N'datetime', N'datetime2', N'smalldatetime', N'datetimeoffset')
			THEN CONVERT(NVARCHAR(4000), CAST(prv.value AS DATETIME2(7)), 126)
		ELSE CONVERT(NVARCHAR(4000), prv.value)
	END AS boundaryValue
FROM sys.dm_db_partition_stats AS ps
INNER JOIN sys.objects AS o ON o.object_id = ps.object_id
INNER JOIN sys.partitions AS p ON p.partition_id = ps.partition_id
INNER JOIN sys.indexes AS i ON i.object_id = ps.object_id AND i.index_id = ps.index_id
LEFT JOIN sys.partition_schemes AS psch ON psch.data_space_id = i.data_space_id
LEFT JOIN sys.partition_functions AS pf ON pf.function_id = psch.function_id
LEFT JOIN sys.partition_range_values AS prv
	ON prv.function_id = pf.function_id
	AND prv.boundary_id = ps.partition_number - CAST(pf.boundary_value_on_right AS INT)
WHERE o.is_ms_shipped = 0
	AND o.type IN ('U', 'V')
ORDER BY ps.object_id, ps.index_id, ps.partition_number;
