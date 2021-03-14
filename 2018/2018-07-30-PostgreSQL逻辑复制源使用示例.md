# 逻辑复制源使用示例

逻辑复制源用于安全的跟踪复制进度，远程复制位置和本地表数据变更在一个事务中，保证了一致性。

以下是使用示例:

## 1. 创建复制源

	postgres=# select pg_replication_origin_create('a');
	 pg_replication_origin_create 
	------------------------------
	                            1
	(1 row)

开始时，	源节点的LSN`remote_lsn`和本节点的LSN`local_lsn`都是初始值。

	postgres=# select * from pg_replication_origin_status;
	 local_id | external_id | remote_lsn | local_lsn 
	----------+-------------+------------+-----------
	        1 | a           | 0/0        | 0/0
	(1 row)

## 2. 在会话中设置复制源

	postgres=# select pg_replication_origin_session_setup('a');
	 pg_replication_origin_session_setup 
	-------------------------------------
	 
	(1 row)

## 3. 在事务中更新复制源

	postgres=# begin;
	BEGIN
	postgres=# insert into tbx10 values(11);
	INSERT 0 1
	postgres=# select pg_replication_origin_xact_setup('1/543F8870',now());
	 pg_replication_origin_xact_setup 
	----------------------------------
	 
	(1 row)
	
	postgres=# select * from pg_replication_origin_status;
	 local_id | external_id | remote_lsn | local_lsn 
	----------+-------------+------------+-----------
	        1 | a           | 0/0        | 0/0
	(1 row)
	
	postgres=# commit;
	COMMIT

## 4. 在事务中更新复制源
事务提交后，复制源记录了最新的同步位置

	postgres=# select * from pg_replication_origin_status;
	 local_id | external_id | remote_lsn | local_lsn  
	----------+-------------+------------+------------
	        1 | a           | 1/543F8870 | 0/543F9468
	(1 row)


## 参考
- http://www.postgres.cn/docs/10/replication-origins.html