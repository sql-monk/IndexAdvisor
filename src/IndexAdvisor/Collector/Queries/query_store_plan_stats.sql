-- Статистика виконання планів лише топ-запитів за весь період Query Store; @queryIds має вигляд ',id1,id2,'.
SELECT
	rs.plan_id AS planId,
	SUM(rs.count_executions) AS executionCount,
	CAST(SUM(rs.avg_duration * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS FLOAT) AS avgDurationMs,
	CAST(SUM(rs.avg_cpu_time * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS FLOAT) AS avgCpuMs
FROM sys.query_store_runtime_stats AS rs
INNER JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
WHERE CHARINDEX(N',' + CAST(p.query_id AS NVARCHAR(20)) + N',', @queryIds) > 0
GROUP BY rs.plan_id
ORDER BY rs.plan_id;
