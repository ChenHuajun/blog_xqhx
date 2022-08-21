## 问题

之前生产遇到一个案例，主备机配置的同步复制，同时通过逻辑订阅把变更推送到下游。
下游拿到推送的变更事件后到主库读取数据，却发现没有读到。

## 原因
主库事务提交时，会生成事务提交的事务日志，并把日志发送到备库和订阅端。
由于主备间是同步复制，主库等待应答后，才能结束事务，事务结束前，事务的更新在主库上对其他事务是不可见的。
如果备库上的应答存在较高的延迟，逻辑订阅端会先看到事务提交，导致上面的问题。

## 回避方法
1. 等待一会（比如1秒）再去读主库
2. 检查主库事务有没结束（高并发执行，代价比较高）

## 验证

在主库上设置一个不存在的同步备机，模拟同步备机故障。
```
postgres=# alter system set synchronous_standby_names='any 1 (aa)';
ALTER SYSTEM
postgres=# select pg_reload_conf();
 pg_reload_conf
----------------
 t
(1 row)
```

执行一条insert SQL
```
insert into tb1 values(1);
```
此SQL已经被hang住了。

开启一个新的会话，查看数据，该插入的数据不可见。
```
postgres=# select * from tb1;
 id
----
(0 rows)
```

查看会话,处于SyncRep状态
```
postgres=# select * from pg_stat_activity where pid=2614;
-[ RECORD 1 ]----+------------------------------
datid            | 13892
datname          | postgres
pid              | 2614
leader_pid       |
usesysid         | 10
usename          | postgres
application_name | psql
client_addr      |
client_hostname  |
client_port      | -1
backend_start    | 2022-08-21 22:57:59.691824+08
xact_start       | 2022-08-21 22:58:56.9794+08
query_start      | 2022-08-21 22:58:56.9794+08
state_change     | 2022-08-21 22:58:56.979405+08
wait_event_type  | IPC
wait_event       | SyncRep
state            | active
backend_xid      | 739
backend_xmin     |
query_id         |
query            | insert into tb1 values(1);
backend_type     | client backend
```


查看锁状态，锁记录依然保持。
```
postgres=# select * from pg_locks where pid=2614;
   locktype    | database | relation | page | tuple | virtualxid | transactionid | classid | objid | objsubid | virtualtransaction | pid  |       mode       | granted | fastpath | waitstart
---------------+----------+----------+------+-------+------------+---------------+---------+-------+----------+--------------------+------+------------------+---------+----------+-----------
 relation      |    13892 |    16384 |      |       |            |               |         |       |          | 3/23               | 2614 | RowExclusiveLock | t       | t        |
 virtualxid    |          |          |      |       | 3/23       |               |         |       |          | 3/23               | 2614 | ExclusiveLock    | t       | t        |
 transactionid |          |          |      |       |            |           739 |         |       |          | 3/23               | 2614 | ExclusiveLock    | t       | f        |
(3 rows)
```
可以发现相关的锁没有释放。

通过`kill -9`强杀postgres再重启恢复，发现这条记录已经提交了。
```
postgres=# select * from tb1;
 id
----
  1
(1 row)
```

## 历史
15年的时候曾遇到过类似问题，但是现象是反的。当时尽管主库还没有给客户端应答事务成功，但其他会话已经可以看到事务的结果了，这种行为更不合适。
- [关于PostgreSQL同步复制下主从切换时的数据丢失问题](http://blog.chinaunix.net/uid-20726500-id-5517544.html)

显然，现在的PG版本（不清楚哪个版本修改的，至少PG12以后是没问题的）已经解决了这个问题。

