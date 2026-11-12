-- Усі плани Query Store без XML і без агрегації runtime stats (вузький набір); keyset-пагінація: колектор передає @afterPlanId
-- останнього плану попередньої сторінки. Час останнього виконання береться з самого плану.
SELECT
	p.plan_id AS planId,
	p.query_id AS queryId,
	CONVERT(VARCHAR(18), p.query_plan_hash, 1) AS queryPlanHash,
	p.is_forced_plan AS isForced,
	CAST(SWITCHOFFSET(p.last_execution_time, 0) AS DATETIME2(3)) AS lastExecutionUtc
FROM sys.query_store_plan AS p
WHERE p.plan_id > @afterPlanId
ORDER BY p.plan_id;
