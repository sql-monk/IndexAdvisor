-- Користувацькі бази інстансу (без системних, distribution і знімків) з роллю локальної репліки AG і прапорцями реплікації.
SELECT
	d.database_id AS databaseId,
	d.name AS databaseName,
	CAST(d.compatibility_level AS INT) AS compatibilityLevel,
	d.state_desc AS stateDesc,
	d.is_read_only AS isReadOnly,
	d.recovery_model_desc AS recoveryModel,
	ag.name AS availabilityGroup,
	ars.role_desc AS replicaRole,
	ar.secondary_role_allow_connections_desc AS secondaryAllowConnections,
	d.is_published AS isPublished,
	d.is_merge_published AS isMergePublished,
	d.is_subscribed AS isSubscribed,
	d.is_distributor AS isDistributor,
	CAST(ISNULL(HAS_DBACCESS(d.name), 0) AS BIT) AS hasDbAccess
FROM sys.databases AS d
LEFT JOIN sys.availability_replicas AS ar ON ar.replica_id = d.replica_id
LEFT JOIN sys.availability_groups AS ag ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = d.replica_id
WHERE d.database_id > 4
	AND d.source_database_id IS NULL
	AND d.is_distributor = 0
ORDER BY d.database_id;
