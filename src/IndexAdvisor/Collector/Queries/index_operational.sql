-- Операційна статистика індексів поточної бази (блокування, latch, page splits), підсумована по секціях.
SELECT
	os.object_id AS objectId,
	os.index_id AS indexId,
	SUM(os.leaf_insert_count) AS leafInsertCount,
	SUM(os.leaf_update_count) AS leafUpdateCount,
	SUM(os.leaf_delete_count) AS leafDeleteCount,
	SUM(os.leaf_allocation_count) AS leafPageSplitCount,
	SUM(os.nonleaf_allocation_count) AS nonleafPageSplitCount,
	SUM(os.row_lock_wait_count) AS rowLockWaitCount,
	SUM(os.row_lock_wait_in_ms) AS rowLockWaitMs,
	SUM(os.page_lock_wait_count) AS pageLockWaitCount,
	SUM(os.page_lock_wait_in_ms) AS pageLockWaitMs,
	SUM(os.page_latch_wait_count) AS pageLatchWaitCount,
	SUM(os.page_latch_wait_in_ms) AS pageLatchWaitMs,
	SUM(os.page_io_latch_wait_count) AS pageIoLatchWaitCount,
	SUM(os.page_io_latch_wait_in_ms) AS pageIoLatchWaitMs,
	SUM(os.index_lock_promotion_count) AS lockEscalationCount
FROM sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) AS os
GROUP BY os.object_id, os.index_id
ORDER BY os.object_id, os.index_id;
