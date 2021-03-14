# PostgreSQL bug 15290并行索引扫描导致连接hang

## 故障现象

生产环境遇到一个Bug，并行索引扫描可能导致连接hang。

	postgres=# select pid,client_addr,xact_start,now()-xact_start xact_time,wait_event_type,wait_event,state,query from pg_stat_activity where state<>'idle' and pid<>pg_backend_pid();
	 pid  | client_addr |          xact_start           |    xact_time    | wait_event_type |    wait_event    | state  |                  query                  
	------+-------------+-------------------------------+-----------------+-----------------+------------------+--------+-----------------------------------------
	 3699 |             | 2018-11-25 13:54:57.762256+08 | 00:04:39.639015 | IPC             | BgWorkerShutdown | active | explain analyze select count(*) from t;
	 3700 |             | 2018-11-25 13:54:57.766055+08 | 00:04:39.635216 | IPC             | BtreePage        | active | explain analyze select count(*) from t;
	 3701 |             | 2018-11-25 13:54:57.766433+08 | 00:04:39.634838 | IPC             | BtreePage        | active | explain analyze select count(*) from t;
	(3 rows)

发生故障后，无法杀死hang的连接，只能强制(-mi)重启PostgreSQL。

该故障已在10.5中fix，详见

- https://www.postgresql.org/message-id/153228422922.1395.1746424054206154747%40wrigleys.postgresql.org

## 回避方法

禁用并行索引扫描

	alter system set min_parallel_index_scan_size ='1TB';
	select pg_reload_conf();

## 测试

### 准备

	create table tb1(id int);
	insert into tb1 select generate_series(1,1000000);
	create index on tb1(id);
	
	set enable_seqscan = false;
	set enable_bitmapscan = false;
	set parallel_tuple_cost = 0;
	set parallel_setup_cost = 0;

### 测试1


通过回避方法可以禁用并行"Index Only Scan"

	postgres=# explain select count(*) from tb1 where id<1000000;
	                                                  QUERY PLAN                                                   
	---------------------------------------------------------------------------------------------------------------
	 Finalize Aggregate  (cost=28116.77..28116.78 rows=1 width=8)
	   ->  Gather  (cost=28116.76..28116.77 rows=2 width=8)
	         Workers Planned: 2
	         ->  Partial Aggregate  (cost=28116.76..28116.77 rows=1 width=8)
	               ->  Parallel Index Only Scan using tb1_id_idx on tb1  (cost=0.42..27075.09 rows=416667 width=0)
	                     Index Cond: (id < 1000000)
	(6 rows)
	
	postgres=# set min_parallel_index_scan_size ='1TB';
	SET
	postgres=# explain select count(*) from tb1 where id<1000000;
	                                        QUERY PLAN                                         
	-------------------------------------------------------------------------------------------
	 Aggregate  (cost=35408.43..35408.44 rows=1 width=8)
	   ->  Index Only Scan using tb1_id_idx on tb1  (cost=0.42..32908.43 rows=1000000 width=0)
	         Index Cond: (id < 1000000)
	(3 rows)



通过回避方法也可以禁用并行"Index Scan"

	postgres=# reset min_parallel_index_scan_size;
	RESET
	postgres=# set enable_indexonlyscan =0;
	SET
	postgres=# explain select count(*) from tb1 where id<1000000;
	                                                QUERY PLAN                                                
	----------------------------------------------------------------------------------------------------------
	 Finalize Aggregate  (cost=28116.77..28116.78 rows=1 width=8)
	   ->  Gather  (cost=28116.76..28116.77 rows=2 width=8)
	         Workers Planned: 2
	         ->  Partial Aggregate  (cost=28116.76..28116.77 rows=1 width=8)
	               ->  Parallel Index Scan using tb1_id_idx on tb1  (cost=0.42..27075.09 rows=416667 width=0)
	                     Index Cond: (id < 1000000)
	(6 rows)
	
	postgres=# set min_parallel_index_scan_size ='1TB';
	SET
	postgres=# explain select count(*) from tb1 where id<1000000;
	                                      QUERY PLAN                                      
	--------------------------------------------------------------------------------------
	 Aggregate  (cost=35408.43..35408.44 rows=1 width=8)
	   ->  Index Scan using tb1_id_idx on tb1  (cost=0.42..32908.43 rows=1000000 width=0)
	         Index Cond: (id < 1000000)
	(3 rows)


### 测试2

修改`min_parallel_index_scan_size`可以影响当前已有的连接。

会话1：

	postgres=# reset min_parallel_index_scan_size;
	RESET
	postgres=# explain select count(*) from tb1 where id<1000000;
	                                                QUERY PLAN                                                
	----------------------------------------------------------------------------------------------------------
	 Finalize Aggregate  (cost=28116.77..28116.78 rows=1 width=8)
	   ->  Gather  (cost=28116.76..28116.77 rows=2 width=8)
	         Workers Planned: 2
	         ->  Partial Aggregate  (cost=28116.76..28116.77 rows=1 width=8)
	               ->  Parallel Index Scan using tb1_id_idx on tb1  (cost=0.42..27075.09 rows=416667 width=0)
	                     Index Cond: (id < 1000000)
	(6 rows)



会话2：

	postgres=# alter system set min_parallel_index_scan_size ='1TB';
	ALTER SYSTEM
	postgres=# select pg_reload_conf();
	 pg_reload_conf 
	----------------
	 t
	(1 row)

会话1：

	postgres=# show min_parallel_index_scan_size;
	 min_parallel_index_scan_size 
	------------------------------
	 1TB
	(1 row)
	
	postgres=# explain select count(*) from tb1 where id<1000000;
	                                      QUERY PLAN                                      
	--------------------------------------------------------------------------------------
	 Aggregate  (cost=35408.43..35408.44 rows=1 width=8)
	   ->  Index Scan using tb1_id_idx on tb1  (cost=0.42..32908.43 rows=1000000 width=0)
	         Index Cond: (id < 1000000)
	(3 rows)


## 测试3
参考本故障社区邮件中的复现方法进行复现并回避。

- https://www.postgresql.org/message-id/CAEepm%3D2aHm9A6dwHCYC2K-4GGZCXWnuiMA__MCaCh%3DO1ni6CGA%40mail.gmail.com

实测可以复现

	set max_parallel_workers_per_gather = 2;
	set min_parallel_index_scan_size = 0;
	set enable_seqscan = false;
	set enable_bitmapscan = false; -- bitmapscan不复现故障。bitmapscan中索引扫描不是并行，用索引扫描出来tid进行堆扫描才会进行并行扫描
	set parallel_tuple_cost = 0;
	set parallel_setup_cost = 0;
	
	set statement_timeout = '20ms'; -- enough to fork, not enough to complete
	explain analyze select count(*) from t;

实施回避方法后不发生
	
	set min_parallel_index_scan_size ='1TB';
	explain analyze select count(*) from t;





