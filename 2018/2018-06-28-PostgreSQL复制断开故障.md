
## 问题

PostgreSQL导入大量数据时，导致备机复制断开

日志中的错误消息如下：

	> FATAL:  terminating walreceiver process due to administrator command
	> LOG:  ecord with incorrect prev-link 3F136/36 at 28/C000098

## 原因

推测导入数据时导致备机的复制状态反馈超时导致主节点断开复制，之后备机读到了已被回收的WAL旧数据。


## 如何处理？

把`pg_wal`中当前正在恢复的WAL删除，再重启备机。PG重启后遇到缺失的WAL会进入流复制模式从主节点上获取WAL。​

示例:

	$ ps -ef|grep recovering
	postgres  2014  2012  0 17:00 ?        00:00:00 postgres: startup process   recovering 000000010000000000000056
	
	pg_ctl stop
	mv 000000010000000000000056 /tmp/
	pg_ctl start


## 参考

检查PostgreSQL邮件列表，发现有类似bug。

### https://www.postgresql.org/message-id/20180523.103409.61588279.horiguchi.kyotaro%40lab.ntt.co.jp

	> When this last error occurs, the recovery is to go on the replica and remove
	> all the WAL logs from the pg_xlog director and then restart Postgresql. 
	> Everything seems to recover and come up fine.  I've done some tests
	> comparing counts between the replica and the primary and everything seems
	> synced just fine from all I can tell.  
	
	
	It is right recovery steps, as far as looking the attached log
	messages.
	
	A segment is not cleard on recycling. walreceiver writes WAL
	record by record so startup process can see arbitrary byte
	sequence after the last valid record when replication connection
	is lost or standby is restarted.

### https://www.postgresql.org/message-id/20180426.195304.118373455.horiguchi.kyotaro@lab.ntt.co.jp

	A segment is not cleard on recycling. walreceiver writes WAL
	record by record so startup process can see arbitrary byte
	sequence after the last valid record when replication connection
	is lost or standby is restarted.
	
	
	The following scenario results in the similar situation.
	
	
	1. create master and standby and run.
	
	
	   It makes happen this easily if wal_keep_segments is set large
	   (20 or so) on master and 0 on standby.
	
	
	2. Write WAL to recycle happens on standby. Explicit checkpoints
	   on standby make it faster. May be required to run several
	   rounds before we see recycled segment on standby.
	
	
	   maybe_loop {
	     master:
	       create table t (a int);
	       insert into t (select a from generate_series(0, 150000) a);
	       delete from t;
	       checkpoint;
	
	
	     standby:
	       checkpoint;
	       <check for recycled segments in pg_wal>
	   }
	
	
	3. stop master
	
	
	4. standby starts to complain that master is missing.
	
	
	  At this time, standby complains for several kinds of failure. I
	  saw 'invalid record length' and 'incorrect prev-link' this
	  time. I saw 'invalid resource manager ID' when mixing different
	  size records. If XLogReadRecord saw a record with impossibly
	  large tot_length there, it will causes the palloc failure and
	  startup process dies.
	
	
	5. If you see 'zero length record', it's nothing interesting.
	  Repeat 3 and 4 to see another.
