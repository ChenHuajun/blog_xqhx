## 概述

PostgreSQL中存在2类统计信息
- 记录表数据分布的统计信息
  这个统计信息存储在`pg_statistic`系统表中，有WAL日志保证其持久性，主备节点数据一致。
  数据库重启，宕机，主备切换都不会丢失数据。

- 记录各性能指标的统计数据，比如每个表被全表扫描的次数。
  这个统计信息默认由stats collector采集并默认存储在`pg_stat_tmp`目录下。
  主备节点各自分别记录统计信息。
  正常停止服务时，统计信息会被写入`pg_stat`目录，启动时再加载到内存，因此不会丢失。
  但是，异常宕机时这些统计信息将全部被清零。
  并且由于主备节点各自分别记录统计信息，如果我们只访问主库，主备切换后，统计信息也会发生切换，基于切换前后的差值计算性能数据会发生偏差。

  需要注意的是PG 15以后，这些统计信息直接存储在共享内存里，stats collector进程也就消失了。
  `pg_stat_tmp`目录下虽然还在，但只是个空目录。但是其他方面还是和原来一样，比如：正常停止服务时，统计信息会被写入`pg_stat`目录。
  以及异常宕机会导致统计信息被清零。

## 示例
以下示例针对stats collector采集计数类统计信息。

### 1. 创建一套主备集群，可以看到主备库各自记录各自的统计信息，互不干扰

**主库统计信息**
```
postgres=# create table tb1(id int,c1 int);
CREATE TABLE
postgres=# insert into tb1 values(1,1);
INSERT 0 1
postgres=# select * from pg_stat_user_tables where relname='tb1';
-[ RECORD 1 ]-------+-------
relid               | 16439
schemaname          | public
relname             | tb1
seq_scan            | 0
seq_tup_read        | 0
idx_scan            |
idx_tup_fetch       |
n_tup_ins           | 1
n_tup_upd           | 0
n_tup_del           | 0
n_tup_hot_upd       | 0
n_live_tup          | 1
n_dead_tup          | 0
n_mod_since_analyze | 1
last_vacuum         |
last_autovacuum     |
last_analyze        |
last_autoanalyze    |
vacuum_count        | 0
autovacuum_count    | 0
analyze_count       | 0
autoanalyze_count   | 0
```

**主库统计信息存储目录**
```
[postgres@mdw ~]$ ll data12/pg_stat
total 0
[postgres@mdw ~]$ ll data12/pg_stat_tmp/
total 20
-rw------- 1 postgres postgres  2033 Sep 23 23:45 db_0.stat
-rw------- 1 postgres postgres 10145 Sep 23 23:45 db_13593.stat
-rw------- 1 postgres postgres   639 Sep 23 23:45 global.stat
```

**备库统计信息**
```
postgres=# select * from pg_stat_user_tables where relname='tb1';
-[ RECORD 1 ]-------+-------
relid               | 16439
schemaname          | public
relname             | tb1
seq_scan            | 0
seq_tup_read        | 0
idx_scan            |
idx_tup_fetch       |
n_tup_ins           | 0
n_tup_upd           | 0
n_tup_del           | 0
n_tup_hot_upd       | 0
n_live_tup          | 0
n_dead_tup          | 0
n_mod_since_analyze | 0
last_vacuum         |
last_autovacuum     |
last_analyze        |
last_autoanalyze    |
vacuum_count        | 0
autovacuum_count    | 0
analyze_count       | 0
autoanalyze_count   | 0

postgres=# select * from tb1;
-[ RECORD 1 ]
id | 1
c1 | 1

postgres=# select * from pg_stat_user_tables where relname='tb1';
-[ RECORD 1 ]-------+-------
relid               | 16439
schemaname          | public
relname             | tb1
seq_scan            | 1
seq_tup_read        | 1
idx_scan            |
idx_tup_fetch       |
n_tup_ins           | 0
n_tup_upd           | 0
n_tup_del           | 0
n_tup_hot_upd       | 0
n_live_tup          | 0
n_dead_tup          | 0
n_mod_since_analyze | 0
last_vacuum         |
last_autovacuum     |
last_analyze        |
last_autoanalyze    |
vacuum_count        | 0
autovacuum_count    | 0
analyze_count       | 0
autoanalyze_count   | 0
```

**备库统计信息存储目录**
```
[postgres@mdw ~]$ ll data12s/pg_stat_tmp/
total 12
-rw------- 1 postgres postgres  681 Sep 23 23:47 db_0.stat
-rw------- 1 postgres postgres 1864 Sep 23 23:47 db_13593.stat
-rw------- 1 postgres postgres  639 Sep 23 23:47 global.stat
```

### 2. 主库停机，统计数据被持久化到`pg_stat`目录

```
[postgres@mdw ~]$ /usr/pg12/bin/pg_ctl -D data12 stop -l logfile
waiting for server to shut down.... done
server stopped
[postgres@mdw ~]$ ll data12/pg_stat
total 20
-rw------- 1 postgres postgres  2033 Sep 23 23:51 db_0.stat
-rw------- 1 postgres postgres 10145 Sep 23 23:51 db_13593.stat
-rw------- 1 postgres postgres   639 Sep 23 23:51 global.stat
[postgres@mdw ~]$ ll data12/pg_stat_tmp/
total 0
```

### 3. 主库启动，统计数据被加载存储到`pg_stat_tmp`目录
```
[postgres@mdw ~]$ /usr/pg12/bin/pg_ctl -D data12 start -l logfile
waiting for server to start.... done
server started
[postgres@mdw ~]$ ll data12/pg_stat
total 0
[postgres@mdw ~]$ ll data12/pg_stat_tmp/
total 8
-rw------- 1 postgres postgres 2033 Sep 23 23:53 db_0.stat
-rw------- 1 postgres postgres  639 Sep 23 23:53 global.stat

[postgres@mdw ~]$ psql
psql (16devel, server 12.11)
Type "help" for help.

postgres=# \x
Expanded display is on.
postgres=# select * from pg_stat_user_tables where relname='tb1';
-[ RECORD 1 ]-------+-------
relid               | 16439
schemaname          | public
relname             | tb1
seq_scan            | 0
seq_tup_read        | 0
idx_scan            |
idx_tup_fetch       |
n_tup_ins           | 1
n_tup_upd           | 0
n_tup_del           | 0
n_tup_hot_upd       | 0
n_live_tup          | 1
n_dead_tup          | 0
n_mod_since_analyze | 1
last_vacuum         |
last_autovacuum     |
last_analyze        |
last_autoanalyze    |
vacuum_count        | 0
autovacuum_count    | 0
analyze_count       | 0
autoanalyze_count   | 0
```

### 4. 主库crash，统计信息清零
```
[postgres@mdw ~]$ /usr/pg12/bin/pg_ctl -D data12 stop -mi -l logfile
waiting for server to shut down.... done
server stopped
[postgres@mdw ~]$ ll data12/pg_stat
total 20
-rw------- 1 postgres postgres  2033 Sep 23 23:55 db_0.stat
-rw------- 1 postgres postgres 10145 Sep 23 23:55 db_13593.stat
-rw------- 1 postgres postgres   639 Sep 23 23:55 global.stat
[postgres@mdw ~]$ ll data12/pg_stat_tmp/
total 0
[postgres@mdw ~]$ /usr/pg12/bin/pg_ctl -D data12 start -l logfile
waiting for server to start.... done
server started
[postgres@mdw ~]$ ll data12/pg_stat
total 0
[postgres@mdw ~]$ ll data12/pg_stat_tmp/
total 16
-rw------- 1 postgres postgres 1357 Sep 23 23:56 db_0.stat
-rw------- 1 postgres postgres 6765 Sep 23 23:56 db_13593.stat
-rw------- 1 postgres postgres  639 Sep 23 23:56 global.stat

[postgres@mdw ~]$ psql
psql (16devel, server 12.11)
Type "help" for help.

postgres=# \x
Expanded display is on.
postgres=# select * from pg_stat_user_tables where relname='tb1';
-[ RECORD 1 ]-------+-------
relid               | 16439
schemaname          | public
relname             | tb1
seq_scan            | 0
seq_tup_read        | 0
idx_scan            |
idx_tup_fetch       |
n_tup_ins           | 0
n_tup_upd           | 0
n_tup_del           | 0
n_tup_hot_upd       | 0
n_live_tup          | 0
n_dead_tup          | 0
n_mod_since_analyze | 0
last_vacuum         |
last_autovacuum     |
last_analyze        |
last_autoanalyze    |
vacuum_count        | 0
autovacuum_count    | 0
analyze_count       | 0
autoanalyze_count   | 0

```

### 5. 触发vacuum，重新收集元组数
```
postgres=# vacuum tb1;
VACUUM
postgres=# select * from pg_stat_user_tables where relname='tb1';
-[ RECORD 1 ]-------+------------------------------
relid               | 16439
schemaname          | public
relname             | tb1
seq_scan            | 0
seq_tup_read        | 0
idx_scan            |
idx_tup_fetch       |
n_tup_ins           | 0
n_tup_upd           | 0
n_tup_del           | 0
n_tup_hot_upd       | 0
n_live_tup          | 1
n_dead_tup          | 0
n_mod_since_analyze | 0
last_vacuum         | 2022-09-23 23:58:51.004414+08
last_autovacuum     |
last_analyze        |
last_autoanalyze    |
vacuum_count        | 1
autovacuum_count    | 0
analyze_count       | 0
autoanalyze_count   | 0
```

### 参考
- http://postgres.cn/docs/12/monitoring-stats.html#MONITORING-STATS-SETUP
