-- Фрагментація одного індексу в режимі LIMITED (лише листовий рівень), зважена за кількістю сторінок секцій.
SELECT
	CAST(SUM(ps.avg_fragmentation_in_percent * ps.page_count) / NULLIF(SUM(ps.page_count), 0) AS FLOAT) AS avgFragmentationPercent,
	SUM(ps.page_count) AS pageCount,
	SUM(ps.fragment_count) AS fragmentCount
FROM sys.dm_db_index_physical_stats(DB_ID(), @objectId, @indexId, NULL, 'LIMITED') AS ps
WHERE ps.alloc_unit_type_desc = N'IN_ROW_DATA';
