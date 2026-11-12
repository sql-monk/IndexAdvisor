# query_store_top_queries

## Description
Топ-запити поточної бази з Query Store за сумарним CPU, логічними читаннями, тривалістю або кількістю виконань за період
(інтервали runtime stats, UTC): кількість виконань і планів, сумарні й середні CPU, тривалість, логічні та фізичні читання,
модуль, у якому виконується запит, текст запиту (перші 4000 символів). Фільтр за іменем таблиці — пошук у тексті запиту.

## Method
Query

## Server

## Database

## Parameters
- @OrderBy: string? {enum=cpu|logicalReads|duration|executions, default=cpu} - Метрика сортування
- @FromUtc: datetime? - Початок періоду (UTC); порожньо — увесь період Query Store
- @ToUtc: datetime? - Кінець періоду (UTC); порожньо — до поточного моменту
- @TableName: string? {maxLength=128} - Ім'я таблиці для пошуку в тексті запиту (порожньо — усі запити)

## Query
```sql
SELECT
	a.queryId,
	q.query_hash AS queryHash,
	OBJECT_SCHEMA_NAME(q.object_id) AS moduleSchemaName,
	OBJECT_NAME(q.object_id) AS moduleName,
	a.planCount,
	a.executionCount,
	a.totalCpuMs,
	a.totalCpuMs / NULLIF(a.executionCount, 0) AS avgCpuMs,
	a.totalDurationMs,
	a.totalDurationMs / NULLIF(a.executionCount, 0) AS avgDurationMs,
	a.totalLogicalReads,
	a.totalLogicalReads / NULLIF(a.executionCount, 0) AS avgLogicalReads,
	a.totalPhysicalReads,
	a.maxDop,
	SWITCHOFFSET(a.firstExecutionTime, '+00:00') AS firstExecutionUtc,
	SWITCHOFFSET(a.lastExecutionTime, '+00:00') AS lastExecutionUtc,
	LEN(qt.query_sql_text) AS queryTextLength,
	LEFT(qt.query_sql_text, 4000) AS queryText
FROM (
	SELECT
		p.query_id AS queryId,
		COUNT(DISTINCT p.plan_id) AS planCount,
		SUM(rs.count_executions) AS executionCount,
		SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0 AS totalCpuMs,
		SUM(rs.avg_duration * rs.count_executions) / 1000.0 AS totalDurationMs,
		SUM(rs.avg_logical_io_reads * rs.count_executions) AS totalLogicalReads,
		SUM(rs.avg_physical_io_reads * rs.count_executions) AS totalPhysicalReads,
		MAX(rs.max_dop) AS maxDop,
		MIN(rs.first_execution_time) AS firstExecutionTime,
		MAX(rs.last_execution_time) AS lastExecutionTime
	FROM sys.query_store_runtime_stats AS rs
	INNER JOIN sys.query_store_runtime_stats_interval AS rsi
		ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
	INNER JOIN sys.query_store_plan AS p
		ON p.plan_id = rs.plan_id
	WHERE (@FromUtc IS NULL OR rsi.end_time > @FromUtc)
		AND (@ToUtc IS NULL OR rsi.start_time < @ToUtc)
	GROUP BY p.query_id
) AS a
INNER JOIN sys.query_store_query AS q
	ON q.query_id = a.queryId
INNER JOIN sys.query_store_query_text AS qt
	ON qt.query_text_id = q.query_text_id
WHERE (@TableName IS NULL OR CHARINDEX(@TableName, qt.query_sql_text) > 0)
ORDER BY
	CASE @OrderBy
		WHEN N'logicalReads' THEN a.totalLogicalReads
		WHEN N'duration' THEN a.totalDurationMs
		WHEN N'executions' THEN a.executionCount
		ELSE a.totalCpuMs
	END DESC,
	a.queryId;
```
