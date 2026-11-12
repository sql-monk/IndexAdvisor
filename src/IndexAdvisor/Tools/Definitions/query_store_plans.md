# query_store_plans

## Description
Плани виконання з Query Store поточної бази для запиту (QueryId) або плани, що використовують індекс (IndexName): індекси в плані,
ознаки scan, key lookup, missing index і неявних конверсій, forced/parallel, рівень сумісності, накопичені виконання й середні
CPU, тривалість і логічні читання, час останнього виконання (UTC), текст запиту (перші 4000 символів). Повний XML плану —
лише при IncludePlanXml = true (великий обсяг: використовуй малий fetch).

## Method
Query

## Server

## Database

## Parameters
- @QueryId: bigint? {min=1} - Ідентифікатор запиту Query Store (порожньо — усі запити)
- @IndexName: string? {maxLength=128} - Ім'я індексу, який має бути в плані (порожньо — без фільтра)
- @IncludePlanXml: bool? {default=false} - Повертати повний XML плану

## Query
```sql
SELECT
	p.plan_id AS planId,
	p.query_id AS queryId,
	OBJECT_SCHEMA_NAME(q.object_id) AS moduleSchemaName,
	OBJECT_NAME(q.object_id) AS moduleName,
	p.is_forced_plan AS isForcedPlan,
	p.is_parallel_plan AS isParallelPlan,
	p.compatibility_level AS compatibilityLevel,
	p.count_compiles AS countCompiles,
	SWITCHOFFSET(p.last_execution_time, '+00:00') AS lastExecutionUtc,
	rs.executionCount,
	rs.avgCpuMs,
	rs.avgDurationMs,
	rs.avgLogicalReads,
	CONVERT(NVARCHAR(MAX), x.planXml.query('declare namespace sp="http://schemas.microsoft.com/sqlserver/2004/07/showplan";
		for $i in distinct-values(//sp:Object/attribute::Index) return string($i)')) AS indexesUsed,
	x.planXml.exist('declare namespace sp="http://schemas.microsoft.com/sqlserver/2004/07/showplan";
		//sp:RelOp[attribute::PhysicalOp = "Table Scan" or attribute::PhysicalOp = "Clustered Index Scan" or attribute::PhysicalOp = "Index Scan"]') AS hasScan,
	x.planXml.exist('declare namespace sp="http://schemas.microsoft.com/sqlserver/2004/07/showplan";
		//sp:IndexScan[attribute::Lookup = "1" or attribute::Lookup = "true"]') AS hasKeyLookup,
	x.planXml.exist('declare namespace sp="http://schemas.microsoft.com/sqlserver/2004/07/showplan";
		//sp:MissingIndexGroup') AS hasMissingIndex,
	x.planXml.exist('declare namespace sp="http://schemas.microsoft.com/sqlserver/2004/07/showplan";
		//sp:PlanAffectingConvert') AS hasImplicitConversion,
	CASE WHEN @IncludePlanXml = 1 THEN p.query_plan END AS queryPlan,
	LEFT(qt.query_sql_text, 4000) AS queryText
FROM sys.query_store_plan AS p
INNER JOIN sys.query_store_query AS q
	ON q.query_id = p.query_id
INNER JOIN sys.query_store_query_text AS qt
	ON qt.query_text_id = q.query_text_id
CROSS APPLY (
	SELECT
		TRY_CONVERT(XML, p.query_plan) AS planXml
) AS x
OUTER APPLY (
	SELECT
		SUM(r.count_executions) AS executionCount,
		SUM(r.avg_cpu_time * r.count_executions) / NULLIF(SUM(r.count_executions), 0) / 1000.0 AS avgCpuMs,
		SUM(r.avg_duration * r.count_executions) / NULLIF(SUM(r.count_executions), 0) / 1000.0 AS avgDurationMs,
		SUM(r.avg_logical_io_reads * r.count_executions) / NULLIF(SUM(r.count_executions), 0) AS avgLogicalReads
	FROM sys.query_store_runtime_stats AS r
	WHERE r.plan_id = p.plan_id
) AS rs
WHERE (@QueryId IS NULL OR p.query_id = @QueryId)
	AND (@IndexName IS NULL OR CHARINDEX(N'Index="' + QUOTENAME(@IndexName) + N'"', p.query_plan) > 0)
ORDER BY p.query_id, p.plan_id;
```
