-- Топ-запити Query Store у вікні аналізу за CPU, logical reads, тривалістю і кількістю виконань (@topN за кожним критерієм).
WITH agg AS (
	SELECT
		p.query_id,
		SUM(rs.count_executions) AS executionCount,
		SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0 AS totalCpuMs,
		SUM(rs.avg_logical_io_reads * rs.count_executions) AS totalLogicalReads,
		SUM(rs.avg_duration * rs.count_executions) / 1000.0 AS totalDurationMs,
		MIN(rs.first_execution_time) AS firstExecutionTime,
		MAX(rs.last_execution_time) AS lastExecutionTime,
		COUNT(DISTINCT rs.plan_id) AS planCount
	FROM sys.query_store_runtime_stats AS rs
	INNER JOIN sys.query_store_runtime_stats_interval AS rsi ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
	INNER JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
	WHERE rsi.start_time >= @fromUtc
		AND rsi.start_time < @toUtc
	GROUP BY p.query_id
),
ranked AS (
	SELECT
		a.query_id,
		a.executionCount,
		a.totalCpuMs,
		a.totalLogicalReads,
		a.totalDurationMs,
		a.firstExecutionTime,
		a.lastExecutionTime,
		a.planCount,
		ROW_NUMBER() OVER (ORDER BY a.totalCpuMs DESC, a.query_id) AS rnCpu,
		ROW_NUMBER() OVER (ORDER BY a.totalLogicalReads DESC, a.query_id) AS rnLogicalReads,
		ROW_NUMBER() OVER (ORDER BY a.totalDurationMs DESC, a.query_id) AS rnDuration,
		ROW_NUMBER() OVER (ORDER BY a.executionCount DESC, a.query_id) AS rnExecutions
	FROM agg AS a
)
SELECT
	r.query_id AS queryId,
	CONVERT(VARCHAR(18), q.query_hash, 1) AS queryHash,
	CASE WHEN q.object_id > 0 THEN OBJECT_SCHEMA_NAME(q.object_id) + N'.' + OBJECT_NAME(q.object_id) END AS objectName,
	LEFT(qt.query_sql_text, 16000) AS queryText,
	CAST(CASE WHEN q.query_parameterization_type > 0 OR qt.query_sql_text LIKE N'(@%' THEN 1 ELSE 0 END AS BIT) AS isParameterized,
	r.executionCount,
	CAST(r.totalCpuMs AS FLOAT) AS totalCpuMs,
	CAST(r.totalLogicalReads AS FLOAT) AS totalLogicalReads,
	CAST(r.totalDurationMs AS FLOAT) AS totalDurationMs,
	r.planCount,
	CAST(SWITCHOFFSET(r.firstExecutionTime, 0) AS DATETIME2(3)) AS firstExecutionUtc,
	CAST(SWITCHOFFSET(r.lastExecutionTime, 0) AS DATETIME2(3)) AS lastExecutionUtc,
	CAST(CASE WHEN r.rnCpu <= @topN THEN 1 ELSE 0 END AS BIT) AS isTopCpu,
	CAST(CASE WHEN r.rnLogicalReads <= @topN THEN 1 ELSE 0 END AS BIT) AS isTopLogicalReads,
	CAST(CASE WHEN r.rnDuration <= @topN THEN 1 ELSE 0 END AS BIT) AS isTopDuration,
	CAST(CASE WHEN r.rnExecutions <= @topN THEN 1 ELSE 0 END AS BIT) AS isTopExecutions
FROM ranked AS r
INNER JOIN sys.query_store_query AS q ON q.query_id = r.query_id
INNER JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
WHERE r.rnCpu <= @topN
	OR r.rnLogicalReads <= @topN
	OR r.rnDuration <= @topN
	OR r.rnExecutions <= @topN
ORDER BY r.query_id;
