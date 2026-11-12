-- Топологія інстансу чи listener одним SELECT: HADR, FCI, групи доступності, репліки та їхній стан.
SELECT
	CAST(ISNULL(SERVERPROPERTY('IsHadrEnabled'), 0) AS INT) AS isHadrEnabled,
	CAST(ISNULL(SERVERPROPERTY('IsClustered'), 0) AS INT) AS isClustered,
	@@SERVERNAME AS serverName,
	ag.name AS agName,
	agl.dns_name AS listenerName,
	ar.replica_server_name AS replicaServerName,
	ar.endpoint_url AS endpointUrl,
	ar.read_only_routing_url AS readOnlyRoutingUrl,
	ars.role_desc AS roleDesc,
	ar.availability_mode_desc AS availabilityMode,
	ar.secondary_role_allow_connections_desc AS secondaryAllowConnections,
	ars.connected_state_desc AS connectedState
FROM sys.dm_os_sys_info AS osi
LEFT JOIN sys.availability_groups AS ag ON 1 = 1
LEFT JOIN sys.availability_group_listeners AS agl ON agl.group_id = ag.group_id
LEFT JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = ar.replica_id
ORDER BY ag.name, ar.replica_server_name, agl.dns_name;
