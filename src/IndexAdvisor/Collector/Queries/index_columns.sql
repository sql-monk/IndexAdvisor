-- Ключові, included-колонки та колонка секціонування індексів.
SELECT
	ic.object_id AS objectId,
	ic.index_id AS indexId,
	ic.index_column_id AS indexColumnId,
	c.name AS columnName,
	CAST(ic.key_ordinal AS INT) AS keyOrdinal,
	ic.is_descending_key AS isDescending,
	ic.is_included_column AS isIncluded,
	CAST(ic.partition_ordinal AS INT) AS partitionOrdinal
FROM sys.index_columns AS ic
INNER JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
INNER JOIN sys.objects AS o ON o.object_id = ic.object_id
WHERE o.is_ms_shipped = 0
	AND o.type IN ('U', 'V')
ORDER BY ic.object_id, ic.index_id, ic.key_ordinal, ic.index_column_id;
