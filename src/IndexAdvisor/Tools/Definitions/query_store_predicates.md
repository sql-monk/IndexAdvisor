# query_store_predicates

## Description
Колонки таблиці, за якими фільтрують запити з Query Store поточної бази (розбір планів): колонки в seek-предикатах і в
залишкових предикатах, ознака доступу до секціонованого об'єкта, накопичені виконання, сумарні CPU і логічні читання,
час останнього виконання (UTC). Значення літералів не повертаються. Для вибору ключа секціонування та індексів.

## Method
Query

## Server

## Database

## Parameters
- @SchemaName: string {maxLength=128} - Схема таблиці
- @TableName: string {maxLength=128} - Ім'я таблиці
- @ColumnName: string? {maxLength=128} - Лише плани з предикатом за цією колонкою (порожньо — усі колонки)

## Query
```sql
SELECT
	p.query_id AS queryId,
	p.plan_id AS planId,
	OBJECT_SCHEMA_NAME(q.object_id) AS moduleSchemaName,
	OBJECT_NAME(q.object_id) AS moduleName,
	CONVERT(NVARCHAR(MAX), x.planXml.query('declare namespace sp="http://schemas.microsoft.com/sqlserver/2004/07/showplan";
		for $c in distinct-values(//sp:SeekPredicates//sp:ColumnReference[attribute::Schema = concat("[", sql:variable("@SchemaName"), "]")
			and attribute::Table = concat("[", sql:variable("@TableName"), "]")]/attribute::Column) return string($c)')) AS seekColumns,
	CONVERT(NVARCHAR(MAX), x.planXml.query('declare namespace sp="http://schemas.microsoft.com/sqlserver/2004/07/showplan";
		for $c in distinct-values(//sp:Predicate//sp:ColumnReference[attribute::Schema = concat("[", sql:variable("@SchemaName"), "]")
			and attribute::Table = concat("[", sql:variable("@TableName"), "]")]/attribute::Column) return string($c)')) AS predicateColumns,
	x.planXml.exist('declare namespace sp="http://schemas.microsoft.com/sqlserver/2004/07/showplan";
		//sp:RelOp[attribute::Partitioned = "1" or attribute::Partitioned = "true"]') AS hasPartitionedAccess,
	rs.executionCount,
	rs.totalCpuMs,
	rs.totalLogicalReads,
	SWITCHOFFSET(p.last_execution_time, '+00:00') AS lastExecutionUtc
FROM sys.query_store_plan AS p
INNER JOIN sys.query_store_query AS q
	ON q.query_id = p.query_id
CROSS APPLY (
	SELECT
		TRY_CONVERT(XML, p.query_plan) AS planXml
) AS x
OUTER APPLY (
	SELECT
		SUM(r.count_executions) AS executionCount,
		SUM(r.avg_cpu_time * r.count_executions) / 1000.0 AS totalCpuMs,
		SUM(r.avg_logical_io_reads * r.count_executions) AS totalLogicalReads
	FROM sys.query_store_runtime_stats AS r
	WHERE r.plan_id = p.plan_id
) AS rs
WHERE CHARINDEX(N'Schema="' + QUOTENAME(@SchemaName) + N'"', p.query_plan) > 0
	AND CHARINDEX(N'Table="' + QUOTENAME(@TableName) + N'"', p.query_plan) > 0
	AND x.planXml.exist('declare namespace sp="http://schemas.microsoft.com/sqlserver/2004/07/showplan";
		//sp:ColumnReference[attribute::Schema = concat("[", sql:variable("@SchemaName"), "]")
			and attribute::Table = concat("[", sql:variable("@TableName"), "]")]') = 1
	AND (@ColumnName IS NULL OR x.planXml.exist('declare namespace sp="http://schemas.microsoft.com/sqlserver/2004/07/showplan";
		//sp:ColumnReference[attribute::Table = concat("[", sql:variable("@TableName"), "]") and attribute::Column = sql:variable("@ColumnName")]') = 1)
ORDER BY rs.executionCount DESC, p.plan_id;
```
