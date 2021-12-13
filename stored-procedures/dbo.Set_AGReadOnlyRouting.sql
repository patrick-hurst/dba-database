CREATE OR ALTER PROCEDURE dbo.Set_AGReadOnlyRouting
    @Action             varchar(10),
    @AGName             nvarchar(128),
    @RoutingListCSV     nvarchar(max)   = NULL,
    @RoutingListPattern nvarchar(max)   = NULL
AS

--If RoutingListPattern
    -- Primary replica will be last
    -- Other replicas will be in alphabetical order
--

-- @Action = ENABLE, DISABLE
-- @AgName can be passed as "ALL"


SET NOCOUNT ON;

IF (@Action = 'DISABLE'
    AND COALESCE(@RoutingListCSV,@RoutingListPattern) IS NOT NULL)
BEGIN
    RAISERROR ('For "DISABLE" @Action, both @RoutingListCSV and @RoutingListPattern must be NULL',16,1)
    RETURN;
END;

WITH RoutingLists AS (
    SELECT ar.group_id ,
            STRING_AGG('N''' + ar.replica_server_name + '''',',') WITHIN GROUP (ORDER BY IIF(ar.replica_server_name = @@SERVERNAME, 9, 0), ar.replica_server_name)
    FROM sys.availability_replicas AS ar
    WHERE ar.replica_server_name LIKE COALESCE(@RoutingListPattern, ar.replica_server_name)
    AND @RoutingListCSV IS NULL
    GROUP BY group_id
    UNION ALL
    SELECT ar.group_id ,
            STRING_AGG('N''' + ar.replica_server_name + '''',',') WITHIN GROUP (ORDER BY l.sort)
    FROM sys.availability_replicas AS ar
    JOIN (SELECT Sort = csv.ID,
                 ReplicaName = csv.Value
            FROM dbo.fn_split(@RoutingListCSV,N',') AS csv) AS l ON l.ReplicaName = ar.replica_server_name
    WHERE @RoutingListPattern IS NULL
    GROUP BY group_id
)
SELECT N'USE [master]

ALTER AVAILABILITY GROUP ' + QUOTENAME(ag.name) + '
    MODIFY REPLICA  ON N''' + ar.name + ''' 
    WITH (PRIMARY_ROLE(READ_ONLY_ROUTING_LIST = (' + 
        CASE 
            WHEN @Action = 'DISABLE' THEN @@SERVERNAME
            WHEN @Action = 'ENABLE'  THEN rl.RoutingList 
        END + '
                                                )
                        )
        );
GO'
FROM sys.availability_groups AS ag
JOIN RoutingLists AS rl ON rl.group_id = ag.group_id
JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id
JOIN sys.dm_hadr_availability_replica_states AS rs ON rs.replica_id = ar.replica_id
WHERE rs.role_desc = N'PRIMARY'
AND ag.is_distributed = 0
AND ar.secondary_role_allow_connections IN (1,2)
AND ag.name = CASE 
                WHEN @AGName = 'ALL' THEN ag.name
                ELSE @AGName
              END;