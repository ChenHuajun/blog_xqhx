# MySQL Utilities 高可用工具体验

MySQL Utilities是MySQL官方的工具集，其中包括高可用相关的几个工具。
以下是对当前最新版本1.6的使用体验。

## 前提条件

- MySQL Server 5.6+
- 基于GTID的复制
- Python 2.6+
- Connector/Python 2.0+


## 环境准备

在1台机器准备3个不同端口的MySQL实例用于测试

- 192.168.107.211:9001(master)
- 192.168.107.211:9002(slave1)
- 192.168.107.211:9003(slave2)

### 软件

- OS: CentOS 7.1
- MySQL: Percona Server 5.7.19
- Python： 2.7.5
- Connector/Python：2.1.7
- mysql-utilities：1.6.5

### 创建MySQL实例1

生成实例1的配置文件my1.cnf

	su - mysql
	cat - >my1.cnf <<EOF
	[mysqld]
	port=9001
	datadir=/var/lib/mysql/data1
	socket=/var/lib/mysql/data1/mysql.sock
	basedir=/usr/
	
	innodb_buffer_pool_size=128M
	explicit_defaults_for_timestamp
	skip-name-resolve
	lower-case-table-names
	expire-logs-days=7
	plugin-load="rpl_semi_sync_master=semisync_master.so;rpl_semi_sync_slave=semisync_slave.so"
	rpl_semi_sync_master_wait_point=AFTER_SYNC
	rpl_semi_sync_master_wait_no_slave=ON
	rpl_semi_sync_master_enabled=ON
	rpl_semi_sync_slave_enabled=ON
	rpl_semi_sync_master_timeout=5000
	
	server-id=9001
	log_bin=binlog
	gtid-mode=ON
	enforce-gtid-consistency=ON
	log-slave-updates=ON
	master-info-repository=TABLE
	relay-log-info-repository=TABLE
	report-host=192.168.107.211
	
	log-error=/var/lib/mysql/data1/mysqld.log
	pid-file=/var/lib/mysql/data1/mysqld.pid
	general-log=ON
	general-log-file=/var/lib/mysql/data1/node1.log
	
	[mysqld_safe]
	pid-file=/var/lib/mysql/data1/mysqld.pid
	socket=/var/lib/mysql/data1/mysql.sock
	nice     = 0
	EOF

创建MySQL实例

	mysqld --defaults-file=my1.cnf  --initialize-insecure
	mysqld --defaults-file=my1.cnf &
	mysql -S data1/mysql.sock -uroot -e "set sql_log_bin=OFF;GRANT ALL PRIVILEGES ON *.* TO 'admin'@'%' IDENTIFIED BY '12345' WITH GRANT OPTION"

### 创建MySQL实例2

	sed s/9001/9002/g my1.cnf | sed s/data1/data2/g >my2.cnf
	mysqld --defaults-file=my2.cnf  --initialize-insecure
	mysqld --defaults-file=my2.cnf &
	mysql -S data2/mysql.sock -uroot -e "set sql_log_bin=OFF;GRANT ALL PRIVILEGES ON *.* TO 'admin'@'%' IDENTIFIED BY '12345' WITH GRANT OPTION"

### 创建MySQL实例3

	sed s/9001/9003/g my1.cnf | sed s/data1/data3/g >my3.cnf
	mysqld --defaults-file=my3.cnf  --initialize-insecure
	mysqld --defaults-file=my3.cnf &
	mysql -S data3/mysql.sock -uroot -e "set sql_log_bin=OFF;GRANT ALL PRIVILEGES ON *.* TO 'admin'@'%' IDENTIFIED BY '12345' WITH GRANT OPTION"


## 利用mysqlreplicate建立复制

	-bash-4.2$ mysqlreplicate --master=admin:12345@192.168.107.211:9001 --slave=admin:12345@192.168.107.211:9002 --rpl-user=repl:repl -v
	WARNING: Using a password on the command line interface can be insecure.
	# master on 192.168.107.211: ... connected.
	# slave on 192.168.107.211: ... connected.
	# master id = 9001
	#  slave id = 9002
	# master uuid = b8ca6259-ab80-11e7-91fc-000c296dd240
	#  slave uuid = d842240c-ab80-11e7-960f-000c296dd240
	# Checking InnoDB statistics for type and version conflicts.
	# Checking storage engines...
	# Checking for binary logging on master...
	# Setting up replication...
	# Granting replication access to replication user...
	# Connecting slave to master...
	# CHANGE MASTER TO MASTER_HOST = '192.168.107.211', MASTER_USER = 'repl', MASTER_PASSWORD = 'repl', MASTER_PORT = 9001, MASTER_AUTO_POSITION=1
	# Starting slave from master's last position...
	# IO status: Waiting for master to send event
	# IO thread running: Yes
	# IO error: None
	# SQL thread running: Yes
	# SQL error: None
	# ...done.

除去各种检查，mysqlreplicate真正做的事很简单。如下

**先在master上创建复制账号**

	CREATE USER 'repl'@'192.168.107.211' IDENTIFIED WITH 'repl'
	GRANT REPLICATION SLAVE ON *.* TO 'repl'@'192.168.107.211' IDENTIFIED WITH 'repl'

mysqlreplicate会为每个Slave创建一个复制账号，除非通过以下SQL发现该账号已经存在。

	SELECT * FROM mysql.user WHERE user = 'repl' and host = '192.168.107.211'

**然后在slave上设置复制**

	CHANGE MASTER TO MASTER_HOST = '192.168.107.211', MASTER_USER = 'repl', MASTER_PASSWORD = 'repl', MASTER_PORT = 9001, MASTER_AUTO_POSITION=1

在启用GTID的情况的下，从哪儿开始复制完全由GTID决定，所以mysqlreplicate中的那些和复制起始位点相关的参数，比如`-b`，统统被无视,其效果相当于`-b`。

注意:mysqlreplicate不会理会当前的复制拓扑，所以如果把master和slave对调再执行一次，就变成主主复制了。


slave1的复制配置好后，用同样的方法配置slave2的复制

	mysqlreplicate --master=admin:12345@192.168.107.211:9001 --slave=admin:12345@192.168.107.211:9003 --rpl-user=repl:repl -v


## 通过mysqlrplshow查看复制拓扑

	-bash-4.2$ mysqlrplshow --master=admin:12345@192.168.107.211:9001 --discover-slaves-login=admin:12345 -v 
	WARNING: Using a password on the command line interface can be insecure.
	# master on 192.168.107.211: ... connected.
	# Finding slaves for master: 192.168.107.211:9001
	
	# Replication Topology Graph
	192.168.107.211:9001 (MASTER)
	   |
	   +--- 192.168.107.211:9002 [IO: Yes, SQL: Yes] - (SLAVE)
	   |
	   +--- 192.168.107.211:9003 [IO: Yes, SQL: Yes] - (SLAVE)

mysqlrplshow通过在master上执行`SHOW SLAVE HOSTS`发现初步的复制拓扑。
由于Slave停止复制或改变复制源时不能立刻反应到master的`SHOW SLAVE HOSTS`上，所以初步获取的复制拓扑可能存在冗余，
因此，mysqlrplshow还会再连到slave上执行`SHOW SLAVE STATUS`进行确认。


## 通过mysqlrpladmin检查集群健康状态

	-bash-4.2$ mysqlrpladmin --master=admin:12345@192.168.107.211:9001 --slaves=admin:12345@192.168.107.211:9002,admin:12345@192.168.107.211:9003 health
	WARNING: Using a password on the command line interface can be insecure.
	# Checking privileges.
	#
	# Replication Topology Health:
	+------------------+-------+---------+--------+------------+---------+
	| host             | port  | role    | state  | gtid_mode  | health  |
	+------------------+-------+---------+--------+------------+---------+
	| 192.168.107.211  | 9001  | MASTER  | UP     | ON         | OK      |
	| 192.168.107.211  | 9002  | SLAVE   | UP     | ON         | OK      |
	| 192.168.107.211  | 9003  | SLAVE   | UP     | ON         | OK      |
	+------------------+-------+---------+--------+------------+---------+
	# ...done.

## 通过mysqlrpladmin elect挑选合适的新主

	-bash-4.2$ mysqlrpladmin --master=admin:12345@192.168.107.211:9001 --slaves=admin:12345@192.168.107.211:9002,admin:12345@192.168.107.211:9003 elect
	WARNING: Using a password on the command line interface can be insecure.
	# Checking privileges.
	# Electing candidate slave from known slaves.
	# Best slave found is located on 192.168.107.211:9002.
	# ...done.

然而，elect只是从slaves中选出第一个合格的slave，并不考虑复制是否已停止，以及哪个节点的日志更全。

下面把slave1的复制停掉

	mysql -S data2/mysql.sock -uroot -e "stop slave"

再在master执行一条SQL

	mysql -S data1/mysql.sock -uroot -e "create database test"

现在slave1上少了一个事务

	-bash-4.2$ mysqlrpladmin --master=admin:12345@192.168.107.211:9001 --slaves=admin:12345@192.168.107.211:9002,admin:12345@192.168.107.211:9003 gtid
	WARNING: Using a password on the command line interface can be insecure.
	# Checking privileges.
	#
	# UUIDS for all servers:
	+------------------+-------+---------+---------------------------------------+
	| host             | port  | role    | uuid                                  |
	+------------------+-------+---------+---------------------------------------+
	| 192.168.107.211  | 9001  | MASTER  | 5daf1e10-ac41-11e7-bcc4-000c296dd240  |
	| 192.168.107.211  | 9002  | SLAVE   | fe084f45-ac43-11e7-a343-000c296dd240  |
	| 192.168.107.211  | 9003  | SLAVE   | d0af3a6a-ac41-11e7-85e0-000c296dd240  |
	+------------------+-------+---------+---------------------------------------+
	#
	# Transactions executed on the server:
	+------------------+-------+---------+-------------------------------------------+
	| host             | port  | role    | gtid                                      |
	+------------------+-------+---------+-------------------------------------------+
	| 192.168.107.211  | 9001  | MASTER  | 5daf1e10-ac41-11e7-bcc4-000c296dd240:1-3  |
	| 192.168.107.211  | 9002  | SLAVE   | 5daf1e10-ac41-11e7-bcc4-000c296dd240:1-2  |
	| 192.168.107.211  | 9003  | SLAVE   | 5daf1e10-ac41-11e7-bcc4-000c296dd240:1-3  |
	+------------------+-------+---------+-------------------------------------------+
	# ...done.


但elect仍然会选slave1

	-bash-4.2$ mysqlrpladmin --master=admin:12345@192.168.107.211:9001 --slaves=admin:12345@192.168.107.211:9002,admin:12345@192.168.107.211:9003 elect
	WARNING: Using a password on the command line interface can be insecure.
	# Checking privileges.
	# Electing candidate slave from known slaves.
	# Best slave found is located on 192.168.107.211:9002.
	# ...done.

## 通过mysqlrpladmin switchover在线切换主备

	-bash-4.2$ mysqlrpladmin --master=admin:12345@192.168.107.211:9001 --slaves=admin:12345@192.168.107.211:9002,admin:12345@192.168.107.211:9003 --new-master=admin:12345@192.168.107.211:9002 switchover
	WARNING: Using a password on the command line interface can be insecure.
	# Checking privileges.
	# Performing switchover from master at 192.168.107.211:9001 to slave at 192.168.107.211:9002.
	# Checking candidate slave prerequisites.
	# Checking slaves configuration to master.
	# Waiting for slaves to catch up to old master.
	Slave 192.168.107.211:9002 did not catch up to the master.
	ERROR: Slave 192.168.107.211:9002 did not catch up to the master.

switchover会连接到每一个节点并等待所有slave回放完日志才执行切换，因此有任何一个节点故障或任何一个slave复制故障都不会执行switchover。

启动刚才停掉的slave1的复制

	mysql -S data2/mysql.sock -uroot -e "start slave"

再次执行switchover，成功

	-bash-4.2$ mysqlrpladmin --master=admin:12345@192.168.107.211:9001 --slaves=admin:12345@192.168.107.211:9002,admin:12345@192.168.107.211:9003 --new-master=admin:12345@192.168.107.211:9002 --demote-master switchover
	WARNING: Using a password on the command line interface can be insecure.
	# Checking privileges.
	# Performing switchover from master at 192.168.107.211:9001 to slave at 192.168.107.211:9002.
	# Checking candidate slave prerequisites.
	# Checking slaves configuration to master.
	# Waiting for slaves to catch up to old master.
	# Stopping slaves.
	# Performing STOP on all slaves.
	# Demoting old master to be a slave to the new master.
	# Switching slaves to new master.
	# Starting all slaves.
	# Performing START on all slaves.
	# Checking slaves for errors.
	# Switchover complete.
	#
	# Replication Topology Health:
	+------------------+-------+---------+--------+------------+---------+
	| host             | port  | role    | state  | gtid_mode  | health  |
	+------------------+-------+---------+--------+------------+---------+
	| 192.168.107.211  | 9002  | MASTER  | UP     | ON         | OK      |
	| 192.168.107.211  | 9001  | SLAVE   | UP     | ON         | OK      |
	| 192.168.107.211  | 9003  | SLAVE   | UP     | ON         | OK      |
	+------------------+-------+---------+--------+------------+---------+
	# ...done.


执行switchover时，有一段`Waiting for slaves to catch up to old master.`，如果任何一个slave有故障无法同步到和master相同的状态，switchover会失败。即switchover的前提条件是所有节点（包括master和所有salve）都是OK的。

## 通过mysqlrpladmin failover故障切换主备

	-bash-4.2$ mysqlrpladmin --slaves=admin:12345@192.168.107.211:9001,admin:12345@192.168.107.211:9003 failover
	WARNING: Using a password on the command line interface can be insecure.
	# Checking privileges.
	# Performing failover.
	# Candidate slave 192.168.107.211:9001 will become the new master.
	# Checking slaves status (before failover).
	# Preparing candidate for failover.
	# Creating replication user if it does not exist.
	# Stopping slaves.
	# Performing STOP on all slaves.
	# Switching slaves to new master.
	# Disconnecting new master as slave.
	# Starting slaves.
	# Performing START on all slaves.
	# Checking slaves for errors.
	# Failover complete.
	#
	# Replication Topology Health:
	+------------------+-------+---------+--------+------------+---------+
	| host             | port  | role    | state  | gtid_mode  | health  |
	+------------------+-------+---------+--------+------------+---------+
	| 192.168.107.211  | 9001  | MASTER  | UP     | ON         | OK      |
	| 192.168.107.211  | 9003  | SLAVE   | UP     | ON         | OK      |
	+------------------+-------+---------+--------+------------+---------+
	# ...done.

failover时要求所有slave的SQL线程都是正常的，IO线程可以停止或异常。
如果未指定`--candidates`，一般会以slaves中第1个slave作为新主。
如果新主的binlog不是最新的，会先向拥有最新日志的slave复制，并等到binlog追平了再切换。

## 小结

从上面操作过程来看，借助MySQL Utilities管理MySQL集群还比较简便，但结合代码考虑到各种场景，这套工具和MHA比起来还不够严谨。

1. 没有把从库的`READ_ONLY`设置集成到脚本里
2. switchover时没有终止运行中的事务，实际也没有有效的手段阻止新的写事务在旧master上执行。
3. failover不检查master死活，需要DBA在调用failover前自己检查，否则会引起脑裂。

