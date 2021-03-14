# 如何利用pg_resetwal回到过去

PostgreSQL中提供了一个`pg_resetwal`(9.6及以前版本叫`pg_resetxlog`)工具命令，它的本职工作是清理不需要的WAL文件，
但除此以外还能干点别的。详见:

- [http://postgres.cn/docs/9.6/app-pgresetxlog.html](http://postgres.cn/docs/9.6/app-pgresetxlog.html)

根据PG的MVCC实现，更新删除记录时，不是原地更新而新建元组并通过设置标志位使原来的记录成为死元组。
`pg_resetwal`的一项特技是篡改当前事务ID，使得可以访问到这些死元组，只要这些死元组还未被vacuum掉。
下面做个演示。

## 创建测试库

初始化数据库

	[postgres@node1 ~]$ initdb data1
	The files belonging to this database system will be owned by user "postgres".
	This user must also own the server process.
	
	The database cluster will be initialized with locale "en_US.UTF-8".
	The default database encoding has accordingly been set to "UTF8".
	The default text search configuration will be set to "english".
	
	Data page checksums are disabled.
	
	creating directory data1 ... ok
	creating subdirectories ... ok
	selecting default max_connections ... 100
	selecting default shared_buffers ... 128MB
	selecting dynamic shared memory implementation ... posix
	creating configuration files ... ok
	running bootstrap script ... ok
	performing post-bootstrap initialization ... ok
	syncing data to disk ... ok
	
	WARNING: enabling "trust" authentication for local connections
	You can change this by editing pg_hba.conf or using the option -A, or
	--auth-local and --auth-host, the next time you run initdb.
	
	Success. You can now start the database server using:
	
	    pg_ctl -D data1 -l logfile start

启动PG

	[postgres@node1 ~]$ pg_ctl -D data1 -l logfile start
	waiting for server to start.... done
	server started


## 插入测试数据

	[postgres@node1 ~]$ psql
	psql (11devel)
	Type "help" for help.
	
	postgres=# create table tb1(id int);
	CREATE TABLE
	postgres=# insert into tb1 values(1);
	INSERT 0 1
	postgres=# insert into tb1 values(2);
	INSERT 0 1
	postgres=# insert into tb1 values(3);
	INSERT 0 1
	postgres=# insert into tb1 values(4);
	INSERT 0 1
	postgres=# insert into tb1 values(5);
	INSERT 0 1

查看每条记录对应的事务号

	postgres=# select xmin ,* from tb1;
	 xmin | id 
	------+----
	  556 |  1
	  557 |  2
	  558 |  3
	  559 |  4
	  560 |  5
	(5 rows)

## 重置当前事务ID

重置当前事务ID为559

	[postgres@node1 ~]$ pg_ctl -D data1 stop
	waiting for server to shut down.... done
	server stopped
	
	[postgres@node1 ~]$ pg_resetwal -D data1 -x 559
	Write-ahead log reset
	[postgres@node1 ~]$ pg_ctl -D data1 start
	waiting for server to start....2017-09-30 22:59:37.902 CST [11862] LOG:  listening on IPv6 address "::1", port 5432
	2017-09-30 22:59:37.902 CST [11862] LOG:  listening on IPv4 address "127.0.0.1", port 5432
	2017-09-30 22:59:37.906 CST [11862] LOG:  listening on Unix socket "/tmp/.s.PGSQL.5432"
	2017-09-30 22:59:37.927 CST [11863] LOG:  database system was shut down at 2017-09-30 22:59:34 CST
	2017-09-30 22:59:37.935 CST [11862] LOG:  database system is ready to accept connections
	 done
	server started

## 检查数据

事务559及以后事务插入的数据将不再可见。
如果事务559及以后事务删除了数据，并且被删除的元组还没被回收，那么过去的数据也会重新出现。

	[postgres@node1 ~]$ psql
	psql (11devel)
	Type "help" for help.
	
	postgres=# select xmin ,* from tb1;
	 xmin | id 
	------+----
	  556 |  1
	  557 |  2
	  558 |  3
	(3 rows)

如果继续做一个插入，对应事务ID为559，可以惊奇的发现，之前被隐藏的老的559事务插入的数据也出现了。

	postgres=# insert into tb1 values(6);
	INSERT 0 1
	postgres=# select xmin ,* from tb1;
	 xmin | id 
	------+----
	  556 |  1
	  557 |  2
	  558 |  3
	  559 |  4
	  559 |  6
	(5 rows)

再做一个插入，对应事务ID为560，效果和前面一样。

	postgres=# insert into tb1 values(7);
	INSERT 0 1
	postgres=# select xmin ,* from tb1;
	 xmin | id 
	------+----
	  556 |  1
	  557 |  2
	  558 |  3
	  559 |  4
	  560 |  5
	  559 |  6
	  560 |  7
	(7 rows)

## 解释

PG的MVCC机制通过当前事务快照判断元组可见性，对事务快照影响最大的就是当前事务ID，只有小于等于当前事务ID且已提交的事务的变更才对当前事务可见。这也是利用`pg_resetwal`可以在一定程度上回到过去的原因。但是被删除的元组是否能找回依赖于vacuum。

## 如何阻止vacuum

我们可以在一定程度上控制vacuum，比如关闭特定表的autovacuum改为定期通过crontab回收死元组或设置`vacuum_defer_cleanup_age`延迟vacuum。

下面的示例，设置`vacuum_defer_cleanup_age=10`

	postgres=# alter system set vacuum_defer_cleanup_age=10;
	ALTER SYSTEM
	postgres=# select pg_reload_conf();
	 pg_reload_conf 
	----------------
	 t
	(1 row)

准备一些数据并执行删除操作

	postgres=# create table tb1(id int);
	CREATE TABLE
	postgres=# insert into tb1 values(1);
	INSERT 0 1
	postgres=# insert into tb1 values(2);
	INSERT 0 1
	postgres=# select xmin,* from tb1;
	 xmin | id 
	------+----
	  556 |  1
	  557 |  2
	(2 rows)
	postgres=# delete from tb1 where id=2;
	DELETE 1
	postgres=# select xmin,* from tb1;
	 xmin | id 
	------+----
	  556 |  1
	(1 row)

立即执行vacuum不会释放被删除的元组

	postgres=# vacuum VERBOSE tb1;
	INFO:  vacuuming "public.tb1"
	INFO:  "tb1": found 0 removable, 2 nonremovable row versions in 1 out of 1 pages
	DETAIL:  1 dead row versions cannot be removed yet, oldest xmin: 550
	There were 0 unused item pointers.
	Skipped 0 pages due to buffer pins, 0 frozen pages.
	0 pages are entirely empty.
	CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s.
	VACUUM


直到执行一些其它事务，等当前事务号向前推进10个以上，再执行vacuum才能回收这个死元组。

	postgres=# insert into tb1 values(3);
	INSERT 0 1
	postgres=# insert into tb1 values(4);
	INSERT 0 1
	...
	postgres=# vacuum VERBOSE tb1;
	INFO:  vacuuming "public.tb1"
	INFO:  "tb1": removed 1 row versions in 1 pages
	INFO:  "tb1": found 1 removable, 10 nonremovable row versions in 1 out of 1 pages
	DETAIL:  0 dead row versions cannot be removed yet, oldest xmin: 559
	There were 0 unused item pointers.
	Skipped 0 pages due to buffer pins, 0 frozen pages.
	0 pages are entirely empty.
	CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s.
	VACUUM


注意阻止vacuum会导致垃圾堆积数据膨胀，对更新频繁的数据库或表要慎重使用这一技巧。并且这种方式不适用于drop table，vacuum full和truncate ，因为原来的数据文件已经被删了。




