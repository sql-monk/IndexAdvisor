-- Відомості про інстанс і час його запуску (UTC) для інтерпретації обнулення DMV.
SELECT
	@@SERVERNAME AS serverName,
	CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)) AS productVersion,
	CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)) AS productEdition,
	CAST(SERVERPROPERTY('EngineEdition') AS INT) AS engineEdition,
	CAST(ISNULL(SERVERPROPERTY('IsClustered'), 0) AS INT) AS isClustered,
	DATEADD(MINUTE, DATEDIFF(MINUTE, SYSDATETIME(), SYSUTCDATETIME()), osi.sqlserver_start_time) AS sqlserverStartTimeUtc,
	SYSUTCDATETIME() AS collectedAtUtc
FROM sys.dm_os_sys_info AS osi;
