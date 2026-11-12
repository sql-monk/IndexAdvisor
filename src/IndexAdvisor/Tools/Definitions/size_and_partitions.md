# size_and_partitions

## Description
Розмір і секції індексів таблиці з sys.dm_db_partition_stats і каталогів секціонування: по кожній секції — кількість рядків,
зарезервований і використаний обсяг (МБ: in-row, LOB, row-overflow), компресія, файлова група, функція й схема секціонування,
тип межі (RANGE RIGHT/LEFT) та нижня й верхня межі секції. Для виявлення перекосу секцій, порожніх і переповнених секцій.

## Method
Query

## Server

## Database

## Parameters
- @SchemaName: string {maxLength=128} - Схема таблиці
- @TableName: string {maxLength=128} - Ім'я таблиці
- @IndexName: string? {maxLength=128} - Ім'я індексу (порожньо — усі індекси таблиці)

## Query
```sql
SELECT
	s.name AS schemaName,
	t.name AS tableName,
	i.index_id AS indexId,
	i.name AS indexName,
	i.type_desc AS indexType,
	p.partition_number AS partitionNumber,
	ps.row_count AS [rowCount],
	CONVERT(DECIMAL(19, 2), ps.reserved_page_count * 8 / 1024.0) AS reservedMb,
	CONVERT(DECIMAL(19, 2), ps.used_page_count * 8 / 1024.0) AS usedMb,
	CONVERT(DECIMAL(19, 2), ps.in_row_used_page_count * 8 / 1024.0) AS inRowUsedMb,
	CONVERT(DECIMAL(19, 2), ps.lob_used_page_count * 8 / 1024.0) AS lobUsedMb,
	CONVERT(DECIMAL(19, 2), ps.row_overflow_used_page_count * 8 / 1024.0) AS rowOverflowUsedMb,
	p.data_compression_desc AS compression,
	fg.name AS fileGroupName,
	pf.name AS partitionFunction,
	psch.name AS partitionScheme,
	CASE WHEN pf.function_id IS NULL THEN NULL WHEN pf.boundary_value_on_right = 1 THEN N'RIGHT' ELSE N'LEFT' END AS rangeType,
	lo.value AS lowerBoundary,
	hi.value AS upperBoundary
FROM sys.tables AS t
INNER JOIN sys.schemas AS s
	ON s.schema_id = t.schema_id
INNER JOIN sys.indexes AS i
	ON i.object_id = t.object_id
INNER JOIN sys.partitions AS p
	ON p.object_id = i.object_id
	AND p.index_id = i.index_id
INNER JOIN sys.dm_db_partition_stats AS ps
	ON ps.partition_id = p.partition_id
LEFT JOIN sys.partition_schemes AS psch
	ON psch.data_space_id = i.data_space_id
LEFT JOIN sys.partition_functions AS pf
	ON pf.function_id = psch.function_id
LEFT JOIN sys.destination_data_spaces AS dds
	ON dds.partition_scheme_id = psch.data_space_id
	AND dds.destination_id = p.partition_number
LEFT JOIN sys.filegroups AS fg
	ON fg.data_space_id = COALESCE(dds.data_space_id, i.data_space_id)
LEFT JOIN sys.partition_range_values AS lo
	ON lo.function_id = pf.function_id
	AND lo.boundary_id = p.partition_number - 1
LEFT JOIN sys.partition_range_values AS hi
	ON hi.function_id = pf.function_id
	AND hi.boundary_id = p.partition_number
WHERE s.name = @SchemaName
	AND t.name = @TableName
	AND (@IndexName IS NULL OR i.name = @IndexName)
ORDER BY i.index_id, p.partition_number;
```
