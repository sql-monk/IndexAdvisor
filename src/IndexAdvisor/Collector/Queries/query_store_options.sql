-- Налаштування Query Store поточної бази і період наявних даних (UTC).
SELECT
	qso.actual_state_desc AS actualState,
	qso.desired_state_desc AS desiredState,
	qso.readonly_reason AS readOnlyReason,
	CAST(qso.current_storage_size_mb AS FLOAT) AS currentStorageSizeMb,
	CAST(qso.max_storage_size_mb AS FLOAT) AS maxStorageSizeMb,
	qso.stale_query_threshold_days AS staleQueryThresholdDays,
	qso.query_capture_mode_desc AS queryCaptureMode,
	qso.interval_length_minutes AS intervalLengthMinutes,
	(SELECT CAST(SWITCHOFFSET(MIN(rsi.start_time), 0) AS DATETIME2(3)) FROM sys.query_store_runtime_stats_interval AS rsi) AS firstIntervalStartUtc,
	(SELECT CAST(SWITCHOFFSET(MAX(rsi.end_time), 0) AS DATETIME2(3)) FROM sys.query_store_runtime_stats_interval AS rsi) AS lastIntervalEndUtc
FROM sys.database_query_store_options AS qso;
