CREATE TYPE citus.old_shard_placement_drop_method AS ENUM (
   'none', -- do not drop or rename old shards, only record it into citus.citus_move_shard_placement_remained_old_shard
   'rename', -- move old shards to schema "citus_move_shard_placement_recyclebin"
   'drop' -- drop old shards in source node
);

CREATE TABLE citus.citus_move_shard_placement_remained_old_shard(
    id serial primary key,
    optime timestamptz NOT NULL default now(),
    nodename text NOT NULL,
    nodeport text NOT NULL,
    tablename text NOT NULL,
    drop_method citus.old_shard_placement_drop_method NOT NULL
);

-- move this shard and it's all colocated shards from source node to target node.
-- drop_method define how to process old shards in the source node, default is 'none' which does not block SELECT.
-- old shards should be drop in the future will be recorded into table citus.citus_move_shard_placement_remained_old_shard
CREATE OR REPLACE FUNCTION pg_catalog.citus_move_shard_placement(shard_id bigint,
                                              source_node_name text,
                                              source_node_port integer,
                                              target_node_name text,
                                              target_node_port integer,
                                              drop_method citus.old_shard_placement_drop_method DEFAULT 'none')
RETURNS void
AS $citus_move_shard_placement$
    DECLARE
        source_node_id integer;
        source_group_id integer;
        target_node_id integer;
        target_group_id integer;
        logical_relid regclass;
        part_method text;
        source_active_shard_id_array  bigint[];
        source_bad_shards_string text;
        target_exist_shard_id_array bigint[];
        target_shard_tables_with_data text;
        logical_relid_array regclass[];
        logical_schema_array text[];
        logical_table_array text[];
        colocated_table_count integer;
        i integer;
        logical_schema text;
        shard_id_array bigint[];
        shard_fulltablename_array text[];
        tmp_shard_id bigint;
        source_wal_lsn pg_lsn;
        sub_rel_count_srsubid bigint;
        sub_lag numeric;
        error_msg text;
        pub_created boolean := false;
        sub_created boolean := false;
        table_created boolean := false;
        dblink_created boolean := false;
        need_record_source_shard boolean := false;
    BEGIN

    -- check and get node id of target node and target node. Will fail for invalid input.
        IF source_node_name = target_node_name AND source_node_port = target_node_port THEN
            RAISE  'target node can not be same as source node';
        END IF;

        SELECT nodeid, groupid
        INTO   source_node_id,source_group_id
        FROM   pg_dist_node
        WHERE  nodename = source_node_name AND
               nodeport = source_node_port AND
               noderole = 'primary';

        IF source_node_id is NULL OR source_group_id is NULL THEN
            RAISE  'invalid source node %:%', source_node_name, source_node_port;
        END IF;

        SELECT nodeid, groupid
        INTO   target_node_id,target_group_id
        FROM   pg_dist_node
        WHERE  nodename = target_node_name AND
               nodeport = target_node_port AND
               noderole = 'primary';

        IF target_node_id is NULL OR target_group_id is NULL THEN
            RAISE  'invalid target node %:%', target_node_name, target_node_port;
        END IF;

    -- check if the shard is hash shard
        SELECT logicalrelid
        INTO   logical_relid
        FROM   pg_dist_shard
        WHERE  shardid = shard_id;

        IF logical_relid is NULL THEN
            RAISE  'shard % does not esxit', shard_id;
        END IF;

        SELECT partmethod
        INTO   part_method
        FROM   pg_dist_partition
        WHERE  logicalrelid = logical_relid;

        IF part_method is NULL OR part_method <> 'h' THEN
            RAISE  '% is not a hash shard', shard_id;
        END IF;

    -- get all colocated tables and there shard id
        SELECT count(logicalrelid), array_agg(logicalrelid) 
        INTO   STRICT  colocated_table_count,logical_relid_array
        FROM pg_dist_partition 
        WHERE colocationid=(select colocationid from pg_dist_partition where logicalrelid=logical_relid);

        SELECT array_agg(nspname), array_agg(relname)
        INTO   STRICT  logical_schema_array, logical_table_array
        FROM pg_class c
        LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.oid = any(logical_relid_array);

        SELECT array_agg(shardid), array_agg(shard_name(logicalrelid, shardid))
        INTO   STRICT  shard_id_array, shard_fulltablename_array
        FROM pg_dist_shard 
        WHERE logicalrelid = any(logical_relid_array) AND
            (shardminvalue,shardmaxvalue)=(select shardminvalue,shardmaxvalue from pg_dist_shard where shardid=shard_id);

    -- check if all colocated shards are valid
        SELECT array_agg(shardid)
        INTO   source_active_shard_id_array
        FROM   pg_dist_placement
        WHERE  shardid = any(shard_id_array) AND
               groupid = source_group_id AND
               shardstate = 1;

        IF source_active_shard_id_array is NULL THEN
            RAISE  'shard % in source node do not exist or invalid', shard_id_array;
        ELSIF NOT (source_active_shard_id_array @> shard_id_array AND source_active_shard_id_array <@ shard_id_array) THEN
            SELECT string_agg(shardid::text,',')
            INTO   STRICT  source_bad_shards_string
            FROM   unnest(shard_id_array) t(shardid)
            WHERE  shardid <> any(source_active_shard_id_array);

            RAISE  'shard % in source node do not exist or invalid', source_bad_shards_string;
        END IF;

        SELECT array_agg(shardid)
        INTO   target_exist_shard_id_array
        FROM   pg_dist_placement
        WHERE  shardid = shard_id AND
               groupid = target_group_id;

        IF target_exist_shard_id_array is not NULL THEN
            RAISE  'shard % already exist in target node', target_exist_shard_id_array;
        END IF;

        RAISE  NOTICE  'BEGIN move shards(%) from %:% to %:%', 
                    array_to_string(shard_id_array,','),
                    source_node_name, source_node_port,
                    target_node_name, target_node_port;

    --  lock tables from executing DDL
        FOR i IN 1..colocated_table_count LOOP
            RAISE  NOTICE  '[%/%] LOCK TABLE %.% IN SHARE UPDATE EXCLUSIVE MODE ...', 
                            i, colocated_table_count, logical_schema_array[i], logical_table_array[i];

            EXECUTE format('LOCK TABLE %I.%I IN SHARE UPDATE EXCLUSIVE MODE', 
                            logical_schema_array[i],
                            logical_table_array[i]);
        END LOOP;

    -- create dblink connection
        PERFORM dblink_disconnect(con) 
        FROM (select unnest(a) con from dblink_get_connections() a)b 
        WHERE con in ('citus_move_shard_placement_source_con','citus_move_shard_placement_target_con') ;

        PERFORM dblink_connect('citus_move_shard_placement_source_con',
                                format('host=%s port=%s user=%s dbname=%s',
                                        source_node_name,
                                        source_node_port,
                                        current_user,
                                        current_database()));
        dblink_created := true;

        PERFORM dblink_connect('citus_move_shard_placement_target_con',
                                format('host=%s port=%s user=%s dbname=%s',
                                        target_node_name,
                                        target_node_port,
                                        current_user,
                                        current_database()));

        BEGIN
    -- CREATE PUBLICATION in source node
            RAISE  NOTICE  'CREATE PUBLICATION in source node %:%', source_node_name, source_node_port;
            PERFORM dblink_exec('citus_move_shard_placement_source_con', 
                                format('CREATE PUBLICATION citus_move_shard_placement_pub FOR TABLE %s',
                                         (select string_agg(table_name,',') from unnest(shard_fulltablename_array) table_name)));
            pub_created := true;

    -- CREATE SCHEMA IF NOT EXISTS in target node
            FOR logical_schema IN select distinct unnest(logical_schema_array) LOOP
                PERFORM dblink_exec('citus_move_shard_placement_target_con', 
                                format('CREATE SCHEMA IF NOT EXISTS %I',
                                        logical_schema));
            END LOOP;

    -- create shard table in the target node
            RAISE  NOTICE  'create shard table in the target node %:%', target_node_name, target_node_port;
            EXECUTE format($$COPY (select '') to PROGRAM 'pg_dump "host=%s port=%s user=%s dbname=%s" -s -t %s | psql "host=%s port=%s user=%s dbname=%s"'$$,
                            source_node_name,
                            source_node_port,
                            current_user,
                            current_database(),
                            (select string_agg(table_name,' -t') from unnest(shard_fulltablename_array) table_name),
                            target_node_name,
                            target_node_port,
                            current_user,
                            current_database());

            SELECT table_name
            INTO   target_shard_tables_with_data
            FROM   dblink('citus_move_shard_placement_target_con',
                            format($$ select string_agg(table_name,',') table_name from ((select tableoid::regclass::text table_name from %s limit 1))a $$,
                                    (select string_agg(table_name,' limit 1) UNION all (select tableoid::regclass::text table_name from ') 
                                            from unnest(shard_fulltablename_array) table_name))
                    ) as a(table_name text);

            IF target_shard_tables_with_data is not NULL THEN
                RAISE  'shard tables(%) with data has exists in target node', target_shard_tables_with_data;
            END IF;

            table_created := true;

    -- CREATE SUBSCRIPTION on target node
            RAISE  NOTICE  'CREATE SUBSCRIPTION on target node %:%', target_node_name, target_node_port;
            PERFORM dblink_exec('citus_move_shard_placement_target_con', 
                                format($$CREATE SUBSCRIPTION citus_move_shard_placement_sub
                                             CONNECTION 'host=%s port=%s user=%s dbname=%s'
                                             PUBLICATION citus_move_shard_placement_pub$$,
                                             source_node_name,
                                             source_node_port,
                                             current_user,
                                             current_database()));
            sub_created := true;

    -- wait shard data init sync
            RAISE  NOTICE  'wait for init data sync...';
            LOOP
                SELECT count_srsubid
                INTO STRICT sub_rel_count_srsubid
                FROM dblink('citus_move_shard_placement_target_con',
                                    $$SELECT count(srsubid) count_srsubid from pg_subscription, pg_subscription_rel
                                      WHERE pg_subscription.oid=pg_subscription_rel.srsubid            AND
                                            pg_subscription.subname = 'citus_move_shard_placement_sub' AND
                                            (pg_subscription_rel.srsubstate = 's' OR pg_subscription_rel.srsubstate = 'r')$$
                              ) AS t(count_srsubid int);

                IF sub_rel_count_srsubid = colocated_table_count THEN
                    EXIT;
                ELSE
                    PERFORM pg_sleep(1);
                END IF;
            END LOOP;

    --  lock tables from executing SQL
            FOR i IN 1..colocated_table_count LOOP
                IF drop_method = 'none' THEN
                    --  block all sql except for SELECT
                    RAISE  NOTICE  '[%/%] LOCK TABLE %.% IN EXCLUSIVE MODE ...', 
                                i, colocated_table_count, logical_schema_array[i], logical_table_array[i];

                    EXECUTE format('LOCK TABLE %I.%I IN EXCLUSIVE MODE', 
                                logical_schema_array[i],
                                logical_table_array[i]);
                ELSE
                    --  block all sql
                    RAISE  NOTICE  '[%/%] LOCK TABLE %.% ...', 
                                i, colocated_table_count, logical_schema_array[i], logical_table_array[i];

                    EXECUTE format('LOCK TABLE %I.%I', 
                                logical_schema_array[i],
                                logical_table_array[i]);
                END IF;
            END LOOP;

    -- wait shard data sync
            SELECT sourcewallsn 
            INTO STRICT source_wal_lsn
            FROM dblink('citus_move_shard_placement_source_con', 
                                $$select pg_current_wal_insert_lsn()$$
                          ) AS t(sourcewallsn pg_lsn);

            RAISE  NOTICE  'wait for data sync...';

            LOOP
                SELECT lag 
                INTO STRICT sub_lag
                FROM dblink('citus_move_shard_placement_target_con', 
                                    format($$select pg_wal_lsn_diff('%s',latest_end_lsn) 
                                             FROM pg_stat_subscription
                                             WHERE subname = 'citus_move_shard_placement_sub' AND latest_end_lsn is not NULL$$,
                                             source_wal_lsn::text)
                              ) AS t(lag numeric);

                IF sub_lag <= 0 THEN
                    EXIT;
                ELSE
                    PERFORM pg_sleep(1);
                END IF;
            END LOOP;

    -- UPDATE pg_dist_placement
            RAISE  NOTICE  'UPDATE pg_dist_placement';

            UPDATE pg_dist_placement
            SET groupid=target_group_id 
            WHERE shardid=any(shard_id_array) and groupid=source_group_id;

    -- drop old shard
            IF drop_method = 'drop' THEN
                RAISE  NOTICE  'DROP old shard tables in source node';
            ELSIF drop_method = 'rename' THEN
                RAISE  NOTICE  'Move old shard tables in source node to shcema "citus_move_shard_placement_recyclebin"';

                -- CREATE SCHEMA IF NOT EXISTS citus_move_shard_placement_recyclebin
                BEGIN
                    PERFORM dblink_exec('citus_move_shard_placement_source_con', 
                         'CREATE SCHEMA IF NOT EXISTS citus_move_shard_placement_recyclebin');
                EXCEPTION WHEN QUERY_CANCELED or OTHERS THEN
                    GET STACKED DIAGNOSTICS error_msg = MESSAGE_TEXT;
                    RAISE WARNING 'failed to CREATE SCHEMA  citus_move_shard_placement_recyclebin in source:%', error_msg;
                END;
            END IF;

            FOR i IN 1..colocated_table_count LOOP
                IF drop_method = 'drop' THEN
                    BEGIN
                        PERFORM dblink_exec('citus_move_shard_placement_source_con', 
                                            format($$DROP TABLE %s$$,
                                                     shard_fulltablename_array[i]));
                    EXCEPTION WHEN QUERY_CANCELED or OTHERS THEN
                        need_record_source_shard := true;
                        GET STACKED DIAGNOSTICS error_msg = MESSAGE_TEXT;
                        RAISE WARNING 'failed to DROP TABLE % in source:%', shard_fulltablename_array[i], error_msg;
                    END;
                ELSIF drop_method = 'rename' THEN
                    BEGIN
                        PERFORM dblink_exec('citus_move_shard_placement_source_con', 
                                            format($$ALTER TABLE %s SET SCHEMA citus_move_shard_placement_recyclebin$$,
                                                     shard_fulltablename_array[i]));
                    EXCEPTION WHEN QUERY_CANCELED or OTHERS THEN
                        need_record_source_shard := true;
                        GET STACKED DIAGNOSTICS error_msg = MESSAGE_TEXT;
                        RAISE WARNING 'failed to RENAME TABLE % in source:%', shard_fulltablename_array[i], error_msg;
                    END;
                ELSE
                    need_record_source_shard := true;
                END IF;
                
                IF need_record_source_shard THEN
                    BEGIN
                        INSERT INTO citus.citus_move_shard_placement_remained_old_shard(nodename, nodeport, tablename, drop_method) 
                                SELECT source_node_name, source_node_port, shard_fulltablename_array[i], drop_method;
                    EXCEPTION WHEN QUERY_CANCELED or OTHERS THEN
                        GET STACKED DIAGNOSTICS error_msg = MESSAGE_TEXT;
                        RAISE WARNING 'failed to record shard % into citus.citus_move_shard_placement_remained_old_shard:%', 
                                    shard_fulltablename_array[i], error_msg;
                    END;
                END IF;
            END LOOP;

    -- error cleanup
        EXCEPTION WHEN QUERY_CANCELED or OTHERS THEN
            IF sub_created THEN
                BEGIN
                PERFORM dblink_exec('citus_move_shard_placement_target_con', 
                                 'DROP SUBSCRIPTION citus_move_shard_placement_sub');
                EXCEPTION WHEN QUERY_CANCELED or OTHERS THEN
                    GET STACKED DIAGNOSTICS error_msg = MESSAGE_TEXT;
                    RAISE WARNING 'failed to DROP SUBSCRIPTION citus_move_shard_placement_sub in target node:%', error_msg;
                END;
            END IF;

            IF pub_created THEN
                BEGIN
                PERFORM dblink_exec('citus_move_shard_placement_source_con', 
                                 'DROP PUBLICATION citus_move_shard_placement_pub');
                EXCEPTION WHEN QUERY_CANCELED or OTHERS THEN
                    GET STACKED DIAGNOSTICS error_msg = MESSAGE_TEXT;
                    RAISE WARNING 'failed to DROP PUBLICATION citus_move_shard_placement_pub in source node:%', error_msg;
                END;
            END IF;

            IF table_created THEN
                FOR i IN 1..colocated_table_count LOOP
                    BEGIN
                    PERFORM dblink_exec('citus_move_shard_placement_target_con', 
                                     format('DROP TABLE %s',
                                             shard_fulltablename_array[i]));
                    EXCEPTION WHEN QUERY_CANCELED or OTHERS THEN
                        GET STACKED DIAGNOSTICS error_msg = MESSAGE_TEXT;
                        RAISE WARNING 'failed to DROP TABLE % in target node:%', shard_fulltablename_array[i], error_msg;
                    END;
                END LOOP;
            END IF;

            IF dblink_created THEN
            BEGIN
                PERFORM dblink_disconnect(con) 
                FROM (select unnest(a) con from dblink_get_connections() a)b 
                WHERE con in ('citus_move_shard_placement_source_con','citus_move_shard_placement_target_con') ;

                EXCEPTION WHEN QUERY_CANCELED or OTHERS THEN
                    GET STACKED DIAGNOSTICS error_msg = MESSAGE_TEXT;
                    RAISE WARNING 'failed to call dblink_disconnect:%', error_msg;
                END;
            END IF;

            RAISE;
        END;

    -- cleanup
        RAISE  NOTICE  'DROP SUBSCRIPTION and PUBLICATION';

        BEGIN
            PERFORM dblink_exec('citus_move_shard_placement_target_con', 
                         'DROP SUBSCRIPTION citus_move_shard_placement_sub');
        EXCEPTION WHEN QUERY_CANCELED or OTHERS THEN
            GET STACKED DIAGNOSTICS error_msg = MESSAGE_TEXT;
            RAISE WARNING 'failed to DROP SUBSCRIPTION citus_move_shard_placement_sub:%', error_msg;
        END;

        BEGIN
            PERFORM dblink_exec('citus_move_shard_placement_source_con', 
                         'DROP PUBLICATION citus_move_shard_placement_pub');
        EXCEPTION WHEN QUERY_CANCELED or OTHERS THEN
            GET STACKED DIAGNOSTICS error_msg = MESSAGE_TEXT;
            RAISE WARNING 'failed to DROP PUBLICATION citus_move_shard_placement_pub:%', error_msg;
        END;

        BEGIN
        PERFORM dblink_disconnect(con) 
        FROM (select unnest(a) con from dblink_get_connections() a)b 
        WHERE con in ('citus_move_shard_placement_source_con','citus_move_shard_placement_target_con') ;

        EXCEPTION WHEN QUERY_CANCELED or OTHERS THEN
            GET STACKED DIAGNOSTICS error_msg = MESSAGE_TEXT;
            RAISE WARNING 'failed to call dblink_disconnect:%', error_msg;
        END;

        RAISE  NOTICE  'END';
    END;
$citus_move_shard_placement$ LANGUAGE plpgsql SET search_path = 'pg_catalog','public';

-- drop old shards in source node
CREATE OR REPLACE FUNCTION pg_catalog.citus_move_shard_placement_cleanup()
RETURNS void
AS $$
    BEGIN
        delete from citus.citus_move_shard_placement_remained_old_shard where id in
            (select id 
             from (select id,dblink_exec('host='||nodename || ' port='||nodeport,'DROP TABLE IF EXISTS ' || tablename) drop_result 
                   from citus.citus_move_shard_placement_remained_old_shard)a 
             where drop_result='DROP TABLE');

        PERFORM run_command_on_workers('DROP SCHEMA IF EXISTS citus_move_shard_placement_recyclebin CASCADE');
    END;
$$ LANGUAGE plpgsql SET search_path = 'pg_catalog','public';
