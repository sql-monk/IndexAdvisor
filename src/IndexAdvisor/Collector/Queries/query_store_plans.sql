-- Усі плани Query Store, виконані в періоді @fromUtc..@toUtc (колектор передає весь період Query Store);
-- XML showplan повертається лише для першого плану кожного query_plan_hash.
WITH planStats AS (
	SELECT
		rs.plan_id,
		SUM(rs.count_executions) AS executionCount,
		SUM(rs.avg_duration * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS avgDurationMs,
		SUM(rs.avg_cpu_time * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS avgCpuMs,
		MAX(rs.last_execution_time) AS lastExecutionTime
	FROM sys.query_store_runtime_stats AS rs
	INNER JOIN sys.query_store_runtime_stats_interval AS rsi ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
	WHERE rsi.start_time >= @fromUtc
		AND rsi.start_time < @toUtc
	GROUP BY rs.plan_id
)
SELECT
	p.plan_id AS planId,
	p.query_id AS queryId,
	CONVERT(VARCHAR(18), p.query_plan_hash, 1) AS queryPlanHash,
	p.is_forced_plan AS isForced,
	ps.executionCount,
	CAST(ps.avgDurationMs AS FLOAT) AS avgDurationMs,
	CAST(ps.avgCpuMs AS FLOAT) AS avgCpuMs,
	CAST(SWITCHOFFSET(ps.lastExecutionTime, 0) AS DATETIME2(3)) AS lastExecutionUtc,
	CASE WHEN ROW_NUMBER() OVER (PARTITION BY p.query_plan_hash ORDER BY p.plan_id) = 1 THEN p.query_plan END AS queryPlan
FROM planStats AS ps
INNER JOIN sys.query_store_plan AS p ON p.plan_id = ps.plan_id
ORDER BY p.plan_id;
