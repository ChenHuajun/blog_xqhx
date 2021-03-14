#关于MySQL的GTID和crash safe

在测试MySQL基于GTID的复制集群时遇到一些问题，于是看了下GTID的相关资料，整理了一个简单的memo。

##1. GTID的作用

GTID(Global Transaction ID)是MySQL5.6引入的功能，可以在集群全局范围标识事务，取代过去基于文件+POS的复制定位可大大简化复制集群的管理，并且能避免重复执行事务，增强了数据的一致性。


##2. GTID的形式

官方的定义如下:

	GTID = source_id:transaction_id

上面的`source_id`是MySQL实例的唯一标识，在MySQL第一次启动时自动生成并持久化到auto.cnf文件里，`transaction_id`是MySQL实例上执行的事务的唯一标识，通常从1开始递增。
例如：

	3E11FA47-71CA-11E1-9E33-C80AA9429562:23


GTID 的集合（GTIDs）可以用`source_id`+`transaction_id`范围表示，例如

	3E11FA47-71CA-11E1-9E33-C80AA9429562:1-5

复杂一点的是：如果这组 GTIDs 来自不同的 `source_id`，各组 `source_id` 之间用逗号分隔；如果事务序号有多个范围区间，各组范围之间用冒号分隔，例如：

	3E11FA47-71CA-11E1-9E33-C80AA9429562:1-5:11-18,
	2C256447-3F0D-431B-9A12-575BB20C1507:1-27

##3. GTID相关的几个变量

MySQL通过几个局变量维持全局的GTID状态

* `GTID_EXECUTED`  
	表示已经在该实例上执行过的事务； 执行`RESET MASTER` 会将该变量置空; 我们还可以通过设置`GTID_NEXT`在执行一个空事务，来影响`GTID_EXECUTED`
* `GTID_PURGED`   
	已经被删除了binlog的事务，它是`GTID_EXECUTED`的子集，只有在`GTID_EXECUTED`为空时才能设置该变量，修改`GTID_PURGED`会同时更新`GTID_EXECUTED`为和`GTID_PURGED`相同的值。
* `GTID_OWNED`  
	表示正在执行的事务的gtid以及对应的线程ID。
* `GTID_NEXT`  
	SESSION级别变量，表示下一个将被使用的GTID。

可以通过show命令查看gtid相关的变量

	mysql> show global variables like 'gtid%';
	+----------------------+----------------------------------------------+
	| Variable_name        | Value                                        |
	+----------------------+----------------------------------------------+
	| gtid_deployment_step | OFF                                          |
	| gtid_executed        | e10c75be-5c1b-11e6-ab7c-000c29603333:1-29358 |
	| gtid_mode            | ON                                           |
	| gtid_owned           |                                              |
	| gtid_purged          | e10c75be-5c1b-11e6-ab7c-000c29603333:1-29288 |
	+----------------------+----------------------------------------------+
	5 rows in set (0.05 sec)

	mysql> show  variables like 'gtid_next';
	+---------------+-----------+
	| Variable_name | Value     |
	+---------------+-----------+
	| gtid_next     | AUTOMATIC |
	+---------------+-----------+
	1 row in set (0.00 sec)


##4. GTID如何产生?

GTID的生成受`gtid_next`控制。
在Master上，`gtid_next`是默认的`AUTOMATIC`,即GTID在每次事务提交时自动生成。它从当前已执行的GTID集合（即`gtid_executed`）中，找一个大于0的未使用的最小值作为下个事务GTID。同时将GTID写入到binlog（`set gtid_next`记录），在实际的更新事务记录之前。

在Slave上，从binlog先读取到主库的GTID(即`set gtid_next`记录)，而后执行的事务采用该GTID。

这里的潜台词是GTID范围可能不是连续的，会有空洞，可能由于人工干预也可能由于多线程复制(MTS)的原因。

下面通过设置`gtid_next`，我们人为产生了gtid空洞。

	mysql> show master status;
	+---------------+----------+--------------+------------------+----------------------------------------------+
	| File          | Position | Binlog_Do_DB | Binlog_Ignore_DB | Executed_Gtid_Set                            |
	+---------------+----------+--------------+------------------+----------------------------------------------+
	| binlog.000008 |     2522 |              |                  | e10c75be-5c1b-11e6-ab7c-000c29603333:1-29370 |
	+---------------+----------+--------------+------------------+----------------------------------------------+
	1 row in set (0.00 sec)
	
	mysql> set gtid_next='e10c75be-5c1b-11e6-ab7c-000c29603333:29374';
	Query OK, 0 rows affected (0.00 sec)
	
	mysql> begin;commit;
	Query OK, 0 rows affected (0.00 sec)
	
	Query OK, 0 rows affected (0.03 sec)
	
	mysql> set gtid_next='AUTOMATIC';
	Query OK, 0 rows affected (0.00 sec)
	
	mysql> show master status;
	+---------------+----------+--------------+------------------+----------------------------------------------------+
	| File          | Position | Binlog_Do_DB | Binlog_Ignore_DB | Executed_Gtid_Set                                  |
	+---------------+----------+--------------+------------------+----------------------------------------------------+
	| binlog.000008 |     2715 |              |                  | e10c75be-5c1b-11e6-ab7c-000c29603333:1-29370:29374 |
	+---------------+----------+--------------+------------------+----------------------------------------------------+
	1 row in set (0.00 sec)

继续执行事务，MySQL会分配一个最小的未使用GTID,最终会把空洞填上。

	mysql> insert into tba1 values(1);
	Query OK, 1 row affected (0.01 sec)
	
	mysql> show master status;
	+---------------+----------+--------------+------------------+----------------------------------------------------+
	| File          | Position | Binlog_Do_DB | Binlog_Ignore_DB | Executed_Gtid_Set                                  |
	+---------------+----------+--------------+------------------+----------------------------------------------------+
	| binlog.000008 |     2953 |              |                  | e10c75be-5c1b-11e6-ab7c-000c29603333:1-29371:29374 |
	+---------------+----------+--------------+------------------+----------------------------------------------------+
	1 row in set (0.00 sec)

这意味着不能通过GTID中的事务号精确的确定事务顺序，事务的顺序应由事务记录处于binlog中的位置决定。所以关于GTIDs最常见的运算是集合运算而不是事务号比较。


**参考**  
http://dev.mysql.com/doc/refman/5.6/en/replication-gtids-concepts.html

	The generation and lifecycle of a GTID consists of the following steps:
	
	A transaction is executed and committed on the master.
	
	This transaction is assigned a GTID using the master's UUID and the smallest nonzero transaction sequence number 
	not yet used on this server; the GTID is written to the master's binary log (immediately preceding 
	the transaction itself in the log).
	
	After the binary log data is transmitted to the slave and stored in the slave's relay log (using established 
	mechanisms for this process—see Section 17.2, “Replication Implementation”, for details), the slave reads 
	the GTID and sets the value of its gtid_next system variable as this GTID. This tells the slave that 
	the next transaction must be logged using this GTID.
	
	The slave sets gtid_next in a session context.
	
	The slave checks to make sure that this GTID has not already been used to log a transaction in its own binary log.
	 If and only if this GTID has not been used, the slave then writes the GTID and applies the transaction 
	(and writes the transaction to its binary log). By reading and checking the transaction's GTID first, 
	before processing the transaction itself, the slave guarantees not only that no previous transaction 
	having this GTID has been applied on the slave, but also that no other session has already read this GTID 
	but has not yet committed the associated transaction. In other words, multiple clients are not permitted to 
	apply the same transaction concurrently.
		
	Because gtid_next is not empty, the slave does not attempt to generate a GTID for this transaction but instead 
	writes the GTID stored in this variable—that is, the GTID obtained from the master—immediately preceding the 
	transaction in its binary log.


##5. GTID如何持久化？

5.6为支持GTID新增了2个事件

* `Previous_gtids_log_event`  
   在每个binlog文件的开头部分，记录在该binlog文件之前已执行的GTID集合。
* `Gtid_log_event`  
   在每个事务的前面，表明下一个事务的gtid。

MySQL服务器启动时，通过读binlog文件，初始化`gtid_executed`和`gtid_purged`。

* `gtid_executed`为最新中的binlog文件中`Previous_gtids_log_event`和所有`Gtid_log_event`的并集。
* `gtid_purged`为最老的binlog文件中`Previous_gtids_log_event`。

这样，通过读取binlog文件，重启mysql后，`gtid_executed`和`gtid_purged`的值能保持和上次一致。不过，在MySQL crash的场景，这一点只有在设置了`sync_binlog = 1`才能保证。


**参考**

* http://dev.mysql.com/doc/refman/5.6/en/replication-options-gtids.html#sysvar_gtid_executed

		When the server starts, @@global.gtid_executed is initialized to the union of the following two sets:
		
		The GTIDs listed in the Previous_gtids_log_event of the newest binary log
		
		The GTIDs found in every Gtid_log_event in the newest binary log.

* http://dev.mysql.com/doc/refman/5.6/en/replication-options-gtids.html#sysvar_gtid_purged
	
		When the server starts, the global value of gtid_purged is initialized to the set of GTIDs 
	    contained by the Previous_gtid_log_event of the oldest binary log. When a binary log is purged, 
	    gtid_purged is re-read from the binary log that has now become the oldest one.




##6. 基于GTID的复制如何确定复制位点?

GTID的主要作用就是解决binlog复制的定位问题。在`CHANGE MASTER TO`时指定`MASTER_AUTO_POSITION = 1`，MySQL使用新增的 `COM_BINLOG_DUMP_GTID` 协议进行复制。过程如下:

备库发起复制连接时，将自己的已接受和已执行的gtids的并集(后面称为`slave_gtid_executed`)发送给主库。即下面的集合:

	UNION(@@global.gtid_executed, Retrieved_gtid_set - last_received_GTID)

主库将自己的`gtid_executed`和`slave_gtid_executed`的差集的binlog发送给Slave。主库的binlog dump过程如下：

1. 检查`slave_gtid_executed`是否是主库`gtid_executed`的子集，如否那么主备数据可能不一致，报错。
2. 检查主库的`purged_executed`是否是`slave_gtid_executed`的子集，如否代表缺失备库需要的binlog,报错
3. 从最后一个Binlog开始扫描，获取文件头部的`PREVIOUS_GTIDS_LOG_EVENT`，如果它是`slave_gtid_executed`的子集，则这是需要发送给Slave的第一个binlog文件，否则继续向前扫描。 
4. 从第3步找到的binlog文件的开头读取binlog记录，判断binlog记录是否已被包含在`slave_gtid_executed`中，如果已包含跳过不发送。

从上面的过程可知，在指定`MASTER_AUTO_POSITION = 1`时，Master发送哪些binlog记录给Slave，取决于Slave的`gtid_executed`和`Retrieved_Gtid_Set`以及Master的`gtid_executed`，和`relay_log_info`以及`master_log_info`中保存的复制位点没有关系。


**参考**

* http://dev.mysql.com/doc/refman/5.6/en/change-master-to.html   
* 代码:`com_binlog_dump_gtid()->mysql_binlog_send()->find_first_log_not_in_gtid_set()`


##7. 如何确保基于GTID复制的crash safe slave？

有了前面的基础，可以考虑下如何配置才能保证crash safe slave。

要保证crash safe slave，就是要在slave crash后，下次可以接在crash前的地方继续应用日志。在非GTID的复制下，按照下面配置就可以了，这也是我们在各相关文章中见的最多的配置。

	relay_log_info_repository      = TABLE
	relay_log_recovery             = ON

这样可行的原因是，`relay_log_info_repository = TABLE`时，`apply event`和更新`relay_log_info`表在同一个事务里，innodb要么让它们同时生效，要么同时不生效,保证位点信息和已经应用的事务精确匹配。

`relay_log_recovery = ON`时，会抛弃`master_log_info`中记录的复制位点，根据`relay_log_info`的执行位置重新从Master获取binlog，这就避免了relay 未写全导致的问题(比如只有`set gtid_next`记录，没有记录实际的更新事务。其实已经接受的relay log也是可以保留的，只要把末尾不完整的gtid删掉，然后按relay log中记录的master的binlog位点继续复制。)。

以上两点组合，这就可以确保slave crash后，还可以接在上次apply的位点继续接受binlog并apply。

但是，在基于GTID的复制下，规则变了。crash的Slave重启后，从binlog中解析的`gtid_executed`决定了要apply哪些binlog记录。所以binlog必须和innodb存储引擎的数据保持一致。另外mysql启动时，会从relay log文件中获取已接受的GTIDs并更新到读取`Retrieved_Gtid_Set`。由于relay log文件可能不完整，所以需要抛弃已接受的relay log文件。

这样，对于基于GTID的复制，保证crash safe slave的设置就是下面这样。

	sync_binlog                    = 1
	innodb_flush_log_at_trx_commit = 1
	relay_log_recovery             = ON

否则可能会出现重复应用binlog event或者遗漏应用binlog event的问题。我们在进行宕机模拟测试时发现有这个问题，
后来查找官方bug系统，发现这是一个已知的BUG [#70659](http://bugs.mysql.com/bug.php?id=70659)。

但是，这个设置带来了另一个问题，`sync_binlog`和`innodb_flush_log_at_trx_commit`都设置为1对性能的影响还是挺大的，有没有其它方法回避？

方法当然是有的，还是按下面这样设置：

	relay_log_info_repository      = TABLE
	relay_log_recovery             = ON

但是，Slave crash后，按下面的步骤启动复制。

1. 启动mysql，但不开启复制   
   
		mysqld --skip-slave-start

2. 在Slave上查看执行位点（`Relay_Master_Log_File`，`Exec_Master_Log_Pos`）  

		show slave status\G

3. 在Master上解析binlog文件检查该位点对应的GTID  

	    mysqlbinlog -v -v $binlogfile 

4. 在Slave设置`gitd_purged`为已执行位点的之前的GTID集合   

	    reset master;
	    set global gitd_purged='xxxxxxxxx';  

5. 启动复制  

	    start slave

还可以采用另一个类似的方法，获取已执行的GTID集合  。

1. 启动mysql，但不开启复制  

		mysqld --skip-slave-start

2. 在Slave上修改为基于文件POS的复制  

		change master to MASTER_AUTO_POSITION = 0

3. 启动slave IO线程(这里不能启动SQL线程，如果接受到的GTID已经在Slave的gtid_executed里了，会被Slave skip掉)

		start slave io_thread

4. 检查binlog传输的开始位置(即Retrieved_Gtid_Set的值) 

		show slave status\G  

5.  将`gitd_purged`设置为binlog传输位置的前面的GTID的集合，如果`source_id`有多个，当前Master节点以外的`source_id`产生的GTIds也有加上。

	    reset master;
	    set global gitd_purged='xxxxxxxxx';  

6. 修改回auto position的复制  

		change master to MASTER_AUTO_POSITION = 1

7. 启动slave SQL线程  

	    start slave sql_thread

注意，这种变通的方法不适合多线程复制。因为多线程复制可能产生gtid gap和Gap-free low-watermark position，这会导致Salve上重复apply已经apply过的event。后果就是数据不一致或者复制中断，除非设置binlog格式为row模式并且`slave_exec_mode=IDEMPOTENT`,`slave_exec_mode=IDEMPOTENT`允许Slave回放binlog时忽略重复键和找不到键的错误，使得binlog回放具有幂等性，但这也意味着真的出现了主备数据不一致也会被它忽略。


##8. 多线程复制下如何保证crash safe slave？

前面提到了多线程复制，多线程复制下会产生gtid gap和`Gap-free low-watermark position`。
然而在启用GTID的情况下，这都不是事。Slave在apply event时会跳过`gitd_executed`中已经执行过的事件，所以，只要保证`gitd_executed`和innodb引擎的数据一致，并且从Master拉过来的binlog记录没有遗漏即可，出现重复没有关系。

即，在多线程复制+GTID的配置下，保证crash safe slave的设置仍然是：

	sync_binlog                    = 1
	innodb_flush_log_at_trx_commit = 1
	relay_log_recovery             = ON

但是，测试发现在开启多线程复制后，通过kill 虚机的方式模拟Slave宕机，当Slave再启动后start slave失败。
mysql日志中有如下错误消息：

	---------------------------------
	2016-10-26 21:00:23 2699 [Warning] Neither --relay-log nor --relay-log-index were used; so replication may break when this MySQL server acts as a slave and has his hostname changed!! Please use '--relay-log=mysql-relay-bin' to avoid this problem.
	2016-10-26 21:00:24 2699 [Note] Slave: MTS group recovery relay log info based on Worker-Id 1, group_relay_log_name ./mysql-relay-bin.000011, group_relay_log_pos 2017523 group_master_log_name binlog.000007, group_master_log_pos 2017363
	2016-10-26 21:00:24 2699 [ERROR] Error looking for file after ./mysql-relay-bin.000012.
	2016-10-26 21:00:24 2699 [ERROR] Failed to initialize the master info structure
	2016-10-26 21:00:24 2699 [Note] Check error log for additional messages. You will not be able to start replication until the issue is resolved and the server restarted.
	2016-10-26 21:00:24 2699 [Note] Event Scheduler: Loaded 0 events
	2016-10-26 21:00:24 2699 [Note] mysqld: ready for connections.
	Version: '5.6.31-77.0-log'  socket: '/data/mysql/mysql.sock'  port: 3306  Percona Server (GPL), Release 77.0, Revision 5c1061c
	---------------------------------

启动slave时同样报错

	mysql> start slave;
	ERROR 1872 (HY000): Slave failed to initialize relay log info structure from the repository


出现这种现象的原因在于，`relay_log_recovery=1` 且 `slave_parallel_workers>1`的情况下，mysql启动时会进入MTS Group恢复流程，即读取relay log，尝试填补由于多线程复制导致的gap。然后relay log文件由于不是实时刷新的，在relay log文件中找不到gap对应的relay log记录(低水位和高水位之间的relay log,低水位点即`slave_relay_log_info.Relay_log_pos`的值)就会报这个错。

实际上，在GTID模式下，slave在apply event的时候可以跳过重复事件，所以可以安全的从低水位点应用日志，没必要解析relay log文件。
这看上去是一个bug，于是提交了一个bug报告[#83713](https://bugs.mysql.com/bug.php?id=83713)，目前还没有收到回复。

作为回避方法，可以通过`reset slave`清除relay log文件，跳过这个问题。执行步骤如下

    reset slave;
    change master to MASTER_AUTO_POSITION = 1
    start slave;

在这里，单纯的调`reset slave`不能把状态清理干净。`reset slave`可以把`slave_master_info`,`slave_relay_log_info`和`slave_worker_info` 3张表清空，但内部的`Relay_log_info.inited`标志位仍然处于未被初始化状态（由于前面的MTS group recovery出错导致`Relay_log_info.inited`未被初始化），所以直接调用`start slave`后面仍然会出现1594的错误。调用`change master to`时，会再调一次`Relay_log_info`，此时`slave_relay_log_info`为空，所以跳过了MTS group recovery，所以`Relay_log_info`初始化成功。

	Last_SQL_Errno: 1594
	Last_SQL_Error: Relay log read failure: Could not parse relay log event entry. The possible 
	reasons are: the master's binary log is corrupted (you can check this by running 'mysqlbinlog'
	 on the binary log), the slave's relay log is corrupted (you can check this by running 
	'mysqlbinlog' on the relay log), a network problem, or a bug in the master's or slave's MySQL
	 code. If you want to check the master's binary log or slave's relay log, you will be able to 
	know their names by issuing 'SHOW SLAVE STATUS' on this slave.


##9. 如果Master不是crash safe会有什么后果？

Master要想保持crash safe需要按下面的参数进行设置，否则`gtid_executed`会和实际的innodb存储引擎中的数据不一致。

	sync_binlog                    = 1
	innodb_flush_log_at_trx_commit = 1

在复制的场景下，如果发生了failover，crash的旧Master不能直接新的Master建立复制关系，必须从备份恢复做起，否则很可能发生数据不一致。在这两个参数被设置为双1的情况下,到是可以尝试以`MASTER_AUTO_POSITION = 1`和新Master建立复制关系，如果旧Master比新Master多几个crash时的事务，可以被新Master检测出来，这时再从备份恢复也不迟。

如果没有发生failover，crash的Master很快恢复了，那么Slave继续连接到这个Master上可能会发生什么下面的事情

1. 复制中断
  
	  Master由于是弱持久化，丢失了一部分binlog，导致Slave上的数据(`slave_gtid_executed`)比Master(`gtid_executed`)多，复制中断。

2. 主从数据不一致

	  Master的innodb引擎中丢失了一部分数据，而Slave中有这些数据，主从不一致。甚至于，Master基于被截断的binlog上解析出的gtid_executed继续生成GTID，结果新事务的GTID可能是在crash前已经存在的，即同一个GTID代表了不同的事务。

非GTID的复制其实存在类似的问题。所以，在Master配置为弱持久性的情况下，Master发生OS或物理机宕机，安全的做法是切换到备机,或者重新同步主从数据。


##10. 其它

* SRL和RBL下`--replicate-do-db`和`--replicate-ignore-db`的语义不同
	* Statement-based logging评估是基于缺省DB的，而不管实际修改的DB，这个行为有些奇葩，也就是说DB匹配与否，在use的时候已经定了，而执行的SQL无关。
	* Row-based logging 评估是基于实际修改的DB，这个比较合理。

	需要注意的是，实际的binlog的格式是SBL还是RBL，除了依赖`binlog_format`设置还看具体的SQL，比如DDL都是SBL的。
	另外，被忽略的只是实际的更新语句，更新语句前面的`SET @@SESSION.GTID_NEXT='xxx'`还是被执行了的，所以Slave即使没有应用更新，`gtid_executed`还是和Master保持一致的。 

* 查看RBL的binlog记录中SQL

		mysqlbinlog -v --base64-output=DECODE-ROWS 

	或

		mysqlbinlog -v -v


##11. 参考

* [MySQL 5.6 全局事务 ID（GTID）实现原理（一）](http://www.cnblogs.com/aaa103439/p/3560842.html)
* [MySQL 5.6 全局事务 ID（GTID）实现原理（二）](http://www.cnblogs.com/aaa103439/p/3560846.html)
* [MySQL 5.6 全局事务 ID（GTID）实现原理（三）](http://www.cnblogs.com/aaa103439/p/3560851.html)
* [GTID内部实现、运维变化及存在的bug](http://mysqllover.com/?p=594)
* [17.3.2 Handling an Unexpected Halt of a Replication Slave](http://dev.mysql.com/doc/refman/5.6/en/replication-solutions-unexpected-slave-halt.html)
* [MySQL · 功能分析 · 5.6 并行复制实现分析](http://mysql.taobao.org/monthly/2015/08/09/)
* [#83713](https://bugs.mysql.com/bug.php?id=83713)
* [#70659](http://bugs.mysql.com/bug.php?id=70659)

##12. 附录:相关代码

##基于GTID复制的位置定位

Slave线程生成的`gtid_executed`和`Retrieved_Gtid_Set`的并集，然后往Master发送dump请求。

	Rpl_slave.cc
	static int request_dump(THD *thd, MYSQL* mysql, Master_info* mi,
	                        bool *suppress_warnings)
	{
	...
	  enum_server_command command= mi->is_auto_position() ?
	    COM_BINLOG_DUMP_GTID : COM_BINLOG_DUMP;
	...
	  if (command == COM_BINLOG_DUMP_GTID)
	  {
	...
	    if (gtid_executed.add_gtid_set(mi->rli->get_gtid_set()) != RETURN_STATUS_OK ||
	        gtid_executed.add_gtid_set(gtid_state->get_logged_gtids()) !=
	        RETURN_STATUS_OK)                     //生成的gtid_executed和Retrieved_Gtid_Set的并集
	    {
	      global_sid_lock->unlock();
	      goto err;
	    }
	...
	    /*
	      Note: binlog_flags is always 0.  However, in versions up to 5.6
	      RC, the master would check the lowest bit and do something
	      unexpected if it was set; in early versions of 5.6 it would also
	      use the two next bits.  Therefore, for backward compatibility,
	      if we ever start to use the flags, we should leave the three
	      lowest bits unused.
	    */
	    int2store(ptr_buffer, binlog_flags);
	    ptr_buffer+= ::BINLOG_FLAGS_INFO_SIZE;
	    int4store(ptr_buffer, server_id);
	    ptr_buffer+= ::BINLOG_SERVER_ID_INFO_SIZE;
	    int4store(ptr_buffer, BINLOG_NAME_INFO_SIZE);
	    ptr_buffer+= ::BINLOG_NAME_SIZE_INFO_SIZE;
	    memset(ptr_buffer, 0, BINLOG_NAME_INFO_SIZE);  //BINLOG文件名固定为NULL
	    ptr_buffer+= BINLOG_NAME_INFO_SIZE;
	    int8store(ptr_buffer, 4LL);                    //POS固定为4
	    ptr_buffer+= ::BINLOG_POS_INFO_SIZE;
	
	    int4store(ptr_buffer, encoded_data_size);
	    ptr_buffer+= ::BINLOG_DATA_SIZE_INFO_SIZE;
	    gtid_executed.encode(ptr_buffer);              //填充Slave的gtid_executed
	    ptr_buffer+= encoded_data_size;
	
	    command_size= ptr_buffer - command_buffer;
	    DBUG_ASSERT(command_size == (allocation_size - 1));
	  }
	  else
	  {
	...
	
	}



Master在slave_gtid_executed不为空的情况下，将未包含在slave_gtid_executed中的binlog记录发给Slave。

	Rpl_master.cc
	void mysql_binlog_send(THD* thd, char* log_ident, my_off_t pos,
	                       const Gtid_set* slave_gtid_executed, int flags)
	{
	...
	  bool using_gtid_protocol= slave_gtid_executed != NULL;
	...
	  name= search_file_name;
	  if (log_ident[0])
	    mysql_bin_log.make_log_name(search_file_name, log_ident);
	  else
	  {
	    if (using_gtid_protocol)
	    {
	...
	      Sid_map* slave_sid_map= slave_gtid_executed->get_sid_map();
	      DBUG_ASSERT(slave_sid_map);
	      global_sid_lock->wrlock();
	      const rpl_sid &server_sid= gtid_state->get_server_sid();
	      rpl_sidno subset_sidno= slave_sid_map->sid_to_sidno(server_sid);
	      if (!slave_gtid_executed->is_subset_for_sid(gtid_state->get_logged_gtids(),
	                                                  gtid_state->get_server_sidno(),
	                                                  subset_sidno))
	      {
	        errmsg= ER(ER_SLAVE_HAS_MORE_GTIDS_THAN_MASTER);
	        my_errno= ER_MASTER_FATAL_ERROR_READING_BINLOG;
	        global_sid_lock->unlock();
	        GOTO_ERR;
	      }
	...
	      if (!gtid_state->get_lost_gtids()->is_subset(slave_gtid_executed))
	      {
	        errmsg= ER(ER_MASTER_HAS_PURGED_REQUIRED_GTIDS);
	        my_errno= ER_MASTER_FATAL_ERROR_READING_BINLOG;
	        global_sid_lock->unlock();
	        GOTO_ERR;
	      }
	      global_sid_lock->unlock();
	      first_gtid.clear();
	      if (mysql_bin_log.find_first_log_not_in_gtid_set(name,
	                                                       slave_gtid_executed,
	                                                       &first_gtid,
	                                                       &errmsg))
	      {
	         my_errno= ER_MASTER_FATAL_ERROR_READING_BINLOG;
	         GOTO_ERR;
	      }
	    }
	    else
	      name= 0;					// Find first log
	  }
	...
	//后面根据binlog文件名和Pos发送binlog,但在GTID模式下，从头（POS=4）读取binlog但跳过Slave已经执行过的GTID。
	...
	      switch (event_type)
	      {
	...
	      case GTID_LOG_EVENT:
	        if (using_gtid_protocol)
	        {
	...
	          skip_group= slave_gtid_executed->contains_gtid(gtid_ev.get_sidno(sid_map),
	                                                     gtid_ev.get_gno());
	...
	}




###MTS Group恢复报错

开启多线程复制(MTS)的情况下，Slave crash后再启动时在MTS Group恢复读取relay log文件时报错。相关代码如下：

**调用栈**：
	
	Relay_log_info::rli_init_info()
		->init_recovery() //relay_log_recovery=1的时候执行
			->mts_recovery_groups() //slave_parallel_workers>1的时候执行


`mts_recovery_groups()`的主要处理就是查找gap范围内哪些event已经被执行过了，结果保存在`rli->recovery_groups中`。在读取relay log文件的过程中，由于crash时relay log不全，找不到完整的事务记录，报错！
如下：

	int mts_recovery_groups(Relay_log_info *rli)
	{
	MY_BITMAP *groups= &rli->recovery_groups;
	...
	  for (uint it_job= 0; it_job < above_lwm_jobs.elements; it_job++) //遍历所以执行位点在lwm之后的worker（lwm也称为checkpoint，保存在slave_relay_log_info.Relay_log_pos中，lwm之前的event不存在gap）
	  {
	    Slave_worker *w= ((Slave_job_group *)
	                      dynamic_array_ptr(&above_lwm_jobs, it_job))->worker;
	    LOG_POS_COORD w_last= { const_cast<char*>(w->get_group_master_log_name()),
	                            w->get_group_master_log_pos() };
	...
	      while (not_reached_commit &&
	             (ev= Log_event::read_log_event(&log, 0, p_fdle,
	                                            opt_slave_sql_verify_checksum)))
	      {
	...
	          LOG_POS_COORD ev_coord= { (char *) rli->get_group_master_log_name(),
	                                      ev->log_pos };
	...
	          if ((ret= mts_event_coord_cmp(&ev_coord, &w_last)) == 0) //找到worker执行位点对应的relay记录，分配给这个worker的从checkpoint到这个位点的event都已经应用了，设置rli->recovery_groups。
	          {
	...
	            DBUG_PRINT("mts",
	                       ("Doing a shift ini(%lu) end(%lu).",
	                       (w->checkpoint_seqno + 1) - recovery_group_cnt,
	                        w->checkpoint_seqno));
	
	            for (uint i= (w->checkpoint_seqno + 1) - recovery_group_cnt,
	                 j= 0; i <= w->checkpoint_seqno; i++, j++)
	            {
	              if (bitmap_is_set(&w->group_executed, i))
	              {
	                DBUG_PRINT("mts", ("Setting bit %u.", j));
	                bitmap_fast_test_and_set(groups, j);
	              }
	            }
	            not_reached_commit= false;
	          }

	...
	      if (not_reached_commit && rli->relay_log.find_next_log(&linfo, 1)) //由于crash时relay log不全，找不到完整的事务记录，报错！
	      {
	         error= TRUE;
	         sql_print_error("Error looking for file after %s.", linfo.log_file_name);
	         goto err;
	      }
	...
	}


然而在GTID模式下，先填补gap是没有必要的，Slave在apply event时可以自动跳过已执行的事务（即`gtid_executed`）。
而且`init_recovery()`代码里也有下面这段逻辑，把刚才`mts_recovery_groups()`费尽心思找出来的`clear_mts_recovery_groups`又给清空了，这更说明了`mts_recovery_groups()`是在做无用功。通过debug跳过临时mts_recovery_groups()的调用，发现确实可以解决问题，数据也是一致的。

int init_recovery(Master_info* mi, const char** errmsg)
{
...
  if (rli->recovery_parallel_workers)
  {
    /*
      This is not idempotent and a crash after this function and before
      the recovery is actually done may lead the system to an inconsistent
      state.

      This may happen because the gap is not persitent stored anywhere
      and eventually old relay log files will be removed and further
      calculations on the gaps will be impossible.

      We need to improve this. /Alfranio.
    */
    error= mts_recovery_groups(rli);
    if (rli->mts_recovery_group_cnt)
    {
      if (gtid_mode == GTID_MODE_ON)
      {
        rli->recovery_parallel_workers= 0;
        rli->clear_mts_recovery_groups(); //清空rli->recovery_groups
      }
      else
      {
        error= 1;
        sql_print_error("--relay-log-recovery cannot be executed when the slave "
                        "was stopped with an error or killed in MTS mode; "
                        "consider using RESET SLAVE or restart the server "
                        "with --relay-log-recovery = 0 followed by "
                        "START SLAVE UNTIL SQL_AFTER_MTS_GAPS");
      }
    }
  }
...
}









