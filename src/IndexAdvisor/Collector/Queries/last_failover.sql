-- Зміни стану репліки AG із файлів сесії AlwaysOn_health (лише читання) для визначення часу останнього failover.
SELECT
	CAST(xe.timestamp_utc AS DATETIME2(3)) AS eventTimeUtc,
	CAST(xe.event_data AS NVARCHAR(4000)) AS eventData
FROM sys.fn_xe_file_target_read_file(N'AlwaysOn_health*.xel', NULL, NULL, NULL) AS xe
WHERE xe.object_name = N'availability_replica_state_change'
ORDER BY xe.timestamp_utc DESC;
