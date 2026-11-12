# index_operational_stats

## Description
Операційна статистика індексів таблиці з sys.dm_db_index_operational_stats по секціях: вставки, оновлення, видалення на рівні листя,
розщеплення сторінок (leafAllocationCount), range scans і singleton lookups, блокування рядків і сторінок та очікування на них,
ескалації, latch і page IO latch. Лічильники накопичуються з часу запуску інстансу (sqlserverStartTimeUtc, UTC) і можуть
обнулятися, коли метадані індексу вивантажуються з кешу.

## Method
Query

## Server

## Database

## Parameters
- @SchemaName: string {maxLength=128} - Схема таблиці
- @TableName: string {maxLength=128} - Ім'я таблиці
- @IndexName: string? {maxLength=128} - Ім'я індексу (порожньо — усі індекси таблиці)

## Query
```sql
SELECT
	s.name AS schemaName,
	t.name AS tableName,
	i.index_id AS indexId,
	i.name AS indexName,
	i.type_desc AS indexType,
	os.partition_number AS partitionNumber,
	os.leaf_insert_count AS leafInsertCount,
	os.leaf_update_count AS leafUpdateCount,
	os.leaf_delete_count AS leafDeleteCount,
	os.leaf_ghost_count AS leafGhostCount,
	os.leaf_allocation_count AS leafAllocationCount,
	os.nonleaf_allocation_count AS nonleafAllocationCount,
	os.leaf_page_merge_count AS leafPageMergeCount,
	os.range_scan_count AS rangeScanCount,
	os.singleton_lookup_count AS singletonLookupCount,
	os.forwarded_fetch_count AS forwardedFetchCount,
	os.row_lock_count AS rowLockCount,
	os.row_lock_wait_count AS rowLockWaitCount,
	os.row_lock_wait_in_ms AS rowLockWaitMs,
	os.page_lock_count AS pageLockCount,
	os.page_lock_wait_count AS pageLockWaitCount,
	os.page_lock_wait_in_ms AS pageLockWaitMs,
	os.index_lock_promotion_attempt_count AS lockPromotionAttemptCount,
	os.index_lock_promotion_count AS lockPromotionCount,
	os.page_latch_wait_count AS pageLatchWaitCount,
	os.page_latch_wait_in_ms AS pageLatchWaitMs,
	os.page_io_latch_wait_count AS pageIoLatchWaitCount,
	os.page_io_latch_wait_in_ms AS pageIoLatchWaitMs,
	os.tree_page_latch_wait_count AS treePageLatchWaitCount,
	os.tree_page_latch_wait_in_ms AS treePageLatchWaitMs,
	DATEADD(MINUTE, DATEDIFF(MINUTE, SYSDATETIME(), SYSUTCDATETIME()), osi.sqlserver_start_time) AS sqlserverStartTimeUtc
FROM sys.tables AS t
INNER JOIN sys.schemas AS s
	ON s.schema_id = t.schema_id
CROSS APPLY sys.dm_db_index_operational_stats(DB_ID(), t.object_id, NULL, NULL) AS os
INNER JOIN sys.indexes AS i
	ON i.object_id = os.object_id
	AND i.index_id = os.index_id
CROSS JOIN sys.dm_os_sys_info AS osi
WHERE s.name = @SchemaName
	AND t.name = @TableName
	AND (@IndexName IS NULL OR i.name = @IndexName)
ORDER BY i.index_id, os.partition_number;
```
