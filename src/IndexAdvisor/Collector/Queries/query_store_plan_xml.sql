-- XML showplan для пакета планів (по одному на query_plan_hash); @planIds має вигляд ',id1,id2,'.
-- Діапазон @minPlanId..@maxPlanId обмежує читання sys.query_store_plan пакетом: XML не обчислюється для інших планів.
SELECT
	p.plan_id AS planId,
	p.query_plan AS queryPlan
FROM sys.query_store_plan AS p
WHERE p.plan_id BETWEEN @minPlanId AND @maxPlanId
	AND CHARINDEX(N',' + CAST(p.plan_id AS NVARCHAR(20)) + N',', @planIds) > 0
ORDER BY p.plan_id;
