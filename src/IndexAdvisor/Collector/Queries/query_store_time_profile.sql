-- Профіль топ-запитів у вікні аналізу по годинах (UTC) і днях тижня (ISO: 1 — понеділок); @queryIds має вигляд ',id1,id2,'.
SELECT
	p.query_id AS queryId,
	DATEPART(HOUR, SWITCHOFFSET(rsi.start_time, 0)) AS hourUtc,
	DATEDIFF(DAY, CAST('19000101' AS DATE), CAST(SWITCHOFFSET(rsi.start_time, 0) AS DATE)) % 7 + 1 AS isoDayOfWeek,
	SUM(rs.count_executions) AS executionCount,
	CAST(SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0 AS FLOAT) AS cpuMs,
	CAST(SUM(rs.avg_logical_io_reads * rs.count_executions) AS FLOAT) AS logicalReads,
	CAST(SUM(rs.avg_duration * rs.count_executions) / 1000.0 AS FLOAT) AS durationMs
FROM sys.query_store_runtime_stats AS rs
INNER JOIN sys.query_store_runtime_stats_interval AS rsi ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
INNER JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
WHERE rsi.start_time >= @fromUtc
	AND rsi.start_time < @toUtc
	AND CHARINDEX(N',' + CAST(p.query_id AS NVARCHAR(20)) + N',', @queryIds) > 0
GROUP BY
	p.query_id,
	DATEPART(HOUR, SWITCHOFFSET(rsi.start_time, 0)),
	DATEDIFF(DAY, CAST('19000101' AS DATE), CAST(SWITCHOFFSET(rsi.start_time, 0) AS DATE)) % 7 + 1
ORDER BY queryId, hourUtc, isoDayOfWeek;
