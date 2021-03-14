# 关于PostgreSQL逻辑订阅中的复制状态

开启逻辑订阅后，我们要知道复制的状态。这可以通过PG中的几个系统表或视图获取。

## 订阅端

### `pg_subscription_rel`

通过`pg_subscription_rel`可以知道每张表的同步状态

```
postgres=# select * from pg_subscription_rel;
 srsubid | srrelid | srsubstate | srsublsn  
---------+---------+------------+-----------
   18465 |   18446 | r          | 0/453EF50
   18465 |   18453 | r          | 0/453EF88
   18465 |   18459 | r          | 0/453EFC0
(3 rows)
```

- srsubstate
  状态码： i = 初始化， d = 正在复制数据， s = 已同步， r = 准备好 (普通复制)
- srsublsn
  s和r状态时源端的结束LSN。

初始时该表处于i状态，而后PG从发布端copy基表，此时该表处于d状态，基表拷贝完成后记录LSN位置到srsublsn。
之后进入s状态最后再进入r状态，并通过pgoutput逻辑解码从发布端拉取并应用增量数据。

s状态和r状态的区别是什么？
初始拷贝完成后，每个表的sync worker还需要从发布端拉取增量，直到增量部分追到大于等于apply worker的同步位置。
当追上apply worker的同步位置后表变更为s状态，并记录此时的wal位置到`pg_subscription_rel.srsublsn`。

此时srsublsn可能已经到了apply worker同步的前面，所有在commit wal位置小于srsublsn的事务都需要应用。
一旦apply worker追上srsublsn，设置该表为r状态，此时所有订阅范围的表更新事务都需要apply worker应用。

### `pg_stat_subscription`

`pg_stat_subscription`显示每个订阅worker的状态。一个订阅包含一个apply worker，可选的
还有一个或多个进行初始同步的sync worker。
sync worker上的relid指示正在初始同步的表；对于apply worker，relid为NULL。

apply worker的`latest_end_lsn`为已反馈给发布端的LSN位置，一定程度上也可以认为是已完成同步的LSN位置。

```
postgres=# select * from pg_stat_subscription;
 subid | subname |  pid  | relid | received_lsn |      last_msg_send_time       |     last_msg_receipt_time     | latest_end_lsn |      
  latest_end_time        
-------+---------+-------+-------+--------------+-------------------------------+-------------------------------+----------------+------
-------------------------
 18515 | sub1    | 19860 | 18446 |              | 2020-04-24 19:29:10.961417+08 | 2020-04-24 19:29:10.961417+08 |                | 2020-
04-24 19:29:10.961417+08
 18515 | sub1    | 19499 |       | 0/4566B50    | 2020-04-24 19:29:05.946996+08 | 2020-04-24 19:29:05.947017+08 | 0/4566B50      | 2020-
04-24 19:29:05.946996+08
(2 rows)
```

### `pg_replication_origin_status`

`pg_replication_origin_status`包含了从复制源增量同步的最后一个位置

```
postgres=# select * from pg_replication_origin_status;
 local_id | external_id | remote_lsn | local_lsn 
----------+-------------+------------+-----------
        1 | pg_18465    | 0/4540208  | 0/470FFD8
(1 row)
```

上面的`remote_lsn`是订阅端应用的最后一个的WAL记录在源节点的开始LSN位置（即执行这条WAL记录的开头）。
如果源节点上后来又产生了其他和订阅无关的WAL记录(比如更新其他表或后台checkpoint产生的WAL)，不会反映到`pg_replication_origin_status`里。


## 发布端

### `pg_replication_slots`

发布端的`pg_replication_slots`反映了逻辑订阅复制槽的LSN位点。

```
postgres=# select * from pg_replication_slots;
-[ RECORD 1 ]-------+----------
slot_name           | sub1
plugin              | pgoutput
slot_type           | logical
datoid              | 13451
database            | postgres
temporary           | f
active              | t
active_pid          | 14058
xmin                | 
catalog_xmin        | 755
restart_lsn         | 0/4540818
confirmed_flush_lsn | 0/4540850
```

- `restart_lsn`
`restart_lsn`是可能仍被这个槽的消费者要求的最旧WAL地址（LSN），并且因此不会在检查点期间自动被移除。
- `confirmed_flush_lsn`
`confirmed_flush_lsn`代表逻辑槽的消费者已经确认接收数据到什么位置的地址（LSN）。比这个地址更旧的数据已经不再可用。

`confirmed_flush_lsn`是最后一个已同步的WAL记录的结束位置(需要字节对齐，实际是下条WAL的起始位置)。
`restart_lsn`有时候是最后一个已同步的WAL记录的起始位置。

对应订阅范围内的表的更新WAL记录，必须订阅端执行完这条记录才能算已同步；对其他无关的WAL，直接认为是已同步的，继续处理下一条WAL。

在下面的例子中，我们在订阅端锁住一个订阅表，导致订阅端无法应用这条INSERT WAL，所有`confirmed_flush_lsn`就暂停在这条WAL前面(0/4540850)。

```
[postgres@sndsdevdb18 citus]$ pg_waldump worker1/pg_wal/000000010000000000000004 -s 0/045407A8 -n 5
rmgr: XLOG        len (rec/tot):    106/   106, tx:          0, lsn: 0/045407A8, prev 0/04540770, desc: CHECKPOINT_ONLINE redo 0/4540770; tli 1; prev tli 1; fpw true; xid 0:755; oid 24923; multi 1; offset 0; oldest xid 548 in DB 1; oldest multi 1 in DB 1; oldest/newest commit timestamp xid: 555/754; oldest running xid 755; online
rmgr: Standby     len (rec/tot):     50/    50, tx:          0, lsn: 0/04540818, prev 0/045407A8, desc: RUNNING_XACTS nextXid 755 latestCompletedXid 754 oldestRunningXid 755
rmgr: Heap        len (rec/tot):     69/   130, tx:        755, lsn: 0/04540850, prev 0/04540818, desc: INSERT off 2, blkref #0: rel 1663/13451/17988 blk 0 FPW
rmgr: Transaction len (rec/tot):     46/    46, tx:        755, lsn: 0/045408D8, prev 0/04540850, desc: COMMIT 2020-04-24 14:22:20.531476 CST
rmgr: Standby     len (rec/tot):     50/    50, tx:          0, lsn: 0/04540908, prev 0/045408D8, desc: RUNNING_XACTS nextXid 756 latestCompletedXid 755 oldestRunningXid 756
```

### `pg_stat_replication`

对于一个逻辑订阅，`pg_stat_replication`中可以看到apply worker的复制状态，其中的`write_lsn`,`flush_lsn`,`replay_lsn`和`pg_replication_slots`的`confirmed_flush_lsn`值相同。apply worker的复制的`application_name`为订阅名。

```
postgres=# select * from pg_stat_replication ;
  pid  | usesysid | usename  |   application_name    | client_addr | client_hostname | client_port |         backend_start         | bac
kend_xmin |   state   | sent_lsn  | write_lsn | flush_lsn | replay_lsn | write_lag | flush_lag | replay_lag | sync_priority | sync_state
 
-------+----------+----------+-----------------------+-------------+-----------------+-------------+-------------------------------+----
----------+-----------+-----------+-----------+-----------+------------+-----------+-----------+------------+---------------+-----------
-
 19861 |       10 | postgres | sub1_18515_sync_18446 |             |                 |          -1 | 2020-04-24 19:29:10.964055+08 |    
          | startup   |           |           |           |            |           |           |            |             0 | async
 19500 |       10 | postgres | sub1                  |             |                 |          -1 | 2020-04-24 19:26:59.950652+08 |    
          | streaming | 0/4566B50 | 0/4566B50 | 0/4566B50 | 0/4566B50  |           |           |            |             0 | async
(2 rows)
```

可选的还可能看到sync worker临时创建的用于初始同步的复制。sync worker的复制的`application_name`为订阅名加上同步表信息。

为了理解sync worker的复制干嘛用的？我们需要先看一下sync worker的处理逻辑。

sync worker初始同步一张表时，分下面几个步骤
1. 创建临时复制槽，用于sync worker的复制
2. 从源端copy表数据到目的端
3. 记录copy完成时的lsn到`pg_subscription_rel`的srsublsn
4. 对比srsublsn和apply worker当前同步点lsn(`latest_end_lsn`)
    4.1 如果srsublsn小于latest_end_lsn，将同步状态改为s
    4.2 如果srsublsn大于latest_end_lsn，通过1的复制槽拉取本表的增量数据，等追上apply worker后，将同步状态改为s
5. 后续增量同步工作交给apply worker


## 如何判断订阅已经同步?

在所有表都处于s或r状态时，只要发布端的`pg_stat_replication.replay_lsn`追上发布端的当前lsn即可。

如果我们通过逻辑订阅进行数据表切换，可以执行以下步骤确保数据同步
1. 创建订阅并等待所有表完成基本同步
    即所有表在`pg_subscription_rel`中处于s或r状态
2. 在发布端锁表禁止更新
3. 获取发布端当前lsn
4. 获取发布端的`replay_lsn`(或其他等价指标)，如果超过3的lsn，则数据已同步。
5. 如果尚未同步，重复4


## 注意点
以下同步位置信息，反映了已处于s或r状态的表的同步位点。

- `pg_replication_slots`
- `pg_stat_replication`
- `pg_replication_origin_status`

对于尚未完成初始同步的表，订阅端copy完初始数据后，会用一个临时的复制槽拉取增量WAL，直到追上apply worker。
追上后修改同步状态为s，后续的增量同步交给apply worker。
因此我们判断订阅的整体复制LSN位置时，必须等所有表都完成初始同步后才有意义。

## 参考

详细参考：
https://github.com/ChenHuajun/chenhuajun.github.io/blob/master/_posts/2018-07-30-PostgreSQL逻辑订阅处理流程解析.md
