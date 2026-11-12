# table_structure

## Description
Структура індексів таблиці з системних каталогів: тип, PK/UNIQUE, ключові (з DESC) та included-колонки, сумарний розмір ключа в байтах,
фільтр, fill factor, параметри блокувань, простір даних і колонка секціонування, кількість секцій, компресія, кількість рядків,
дата оновлення статистики індексу (UTC). Один рядок на індекс (зокрема HEAP).

## Method
Query

## Server

## Database

## Parameters
- @SchemaName: string {maxLength=128} - Схема таблиці
- @TableName: string {maxLength=128} - Ім'я таблиці

## Query
```sql
SELECT
	s.name AS schemaName,
	t.name AS tableName,
	i.index_id AS indexId,
	i.name AS indexName,
	i.type_desc AS indexType,
	i.is_primary_key AS isPrimaryKey,
	i.is_unique AS isUnique,
	i.is_unique_constraint AS isUniqueConstraint,
	i.is_disabled AS isDisabled,
	i.is_hypothetical AS isHypothetical,
	i.has_filter AS hasFilter,
	i.filter_definition AS filterDefinition,
	i.fill_factor AS [fillFactor],
	i.is_padded AS isPadded,
	i.ignore_dup_key AS ignoreDupKey,
	i.allow_row_locks AS allowRowLocks,
	i.allow_page_locks AS allowPageLocks,
	kc.keyColumns,
	kc.keyMaxBytes,
	ic.includedColumns,
	ds.name AS dataSpaceName,
	ds.type_desc AS dataSpaceType,
	pc.partitionColumn,
	pt.partitionCount,
	pt.compression,
	pt.[rowCount],
	t.is_replicated AS isTableReplicated,
	DATEADD(MINUTE, DATEDIFF(MINUTE, SYSDATETIME(), SYSUTCDATETIME()), STATS_DATE(i.object_id, i.index_id)) AS statsUpdatedUtc
FROM sys.tables AS t
INNER JOIN sys.schemas AS s
	ON s.schema_id = t.schema_id
INNER JOIN sys.indexes AS i
	ON i.object_id = t.object_id
LEFT JOIN sys.data_spaces AS ds
	ON ds.data_space_id = i.data_space_id
OUTER APPLY (
	SELECT
		STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(c.name) + CASE WHEN xc.is_descending_key = 1 THEN N' DESC' ELSE N'' END), N', ')
			WITHIN GROUP (ORDER BY xc.key_ordinal) AS keyColumns,
		SUM(CASE WHEN c.max_length = -1 THEN 8000 ELSE c.max_length END) AS keyMaxBytes
	FROM sys.index_columns AS xc
	INNER JOIN sys.columns AS c
		ON c.object_id = xc.object_id
		AND c.column_id = xc.column_id
	WHERE xc.object_id = i.object_id
		AND xc.index_id = i.index_id
		AND xc.key_ordinal > 0
) AS kc
OUTER APPLY (
	SELECT
		STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(c.name)), N', ') WITHIN GROUP (ORDER BY xc.index_column_id) AS includedColumns
	FROM sys.index_columns AS xc
	INNER JOIN sys.columns AS c
		ON c.object_id = xc.object_id
		AND c.column_id = xc.column_id
	WHERE xc.object_id = i.object_id
		AND xc.index_id = i.index_id
		AND xc.is_included_column = 1
) AS ic
OUTER APPLY (
	SELECT
		MAX(c.name) AS partitionColumn
	FROM sys.index_columns AS xc
	INNER JOIN sys.columns AS c
		ON c.object_id = xc.object_id
		AND c.column_id = xc.column_id
	WHERE xc.object_id = i.object_id
		AND xc.index_id = i.index_id
		AND xc.partition_ordinal = 1
) AS pc
OUTER APPLY (
	SELECT
		COUNT(*) AS partitionCount,
		SUM(p.rows) AS [rowCount],
		CASE
			WHEN MIN(p.data_compression_desc) = MAX(p.data_compression_desc) THEN MIN(p.data_compression_desc)
			ELSE N'MIXED'
		END AS compression
	FROM sys.partitions AS p
	WHERE p.object_id = i.object_id
		AND p.index_id = i.index_id
) AS pt
WHERE s.name = @SchemaName
	AND t.name = @TableName
ORDER BY i.index_id;
```
