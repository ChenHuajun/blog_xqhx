# PostgreSQL如何保障数据的一致性

玩过MySQL的人应该都知道，由于MySQL是逻辑复制，从根子上是难以保证数据一致性的。玩MySQL玩得好的专家们知道有哪些坑，应该怎么回避。为了保障MySQL数据的一致性，甚至会动用paxos，raft之类的终极武器建立严密的防护网。如果不会折腾，真不建议用MySQL存放一致性要求高的数据。

PostgreSQL由于是物理复制，天生就很容易保障数据一致性，而且回放日志的效率很高。
我们实测的结果，MySQL5.6的写qps超过4000备机就跟不上主机了；PG 8核虚机的写qps压到2.3w备机依然毫无压力,之所以只压到2.3w是因为主节点的CPU已经跑满压不上去了。

那么，和MySQL相比，PG有哪些措施用于保障数据的一致性呢？

## 1. 严格单写

PG的备库处于恢复状态，不断的回放主库的WAL，不具备写能力。

而MySQL的单写是通过在备机上设置`read_only`或`super_read_only`实现的，DBA在维护数据库的时候可能需要解除只读状态，在解除期间发生点什么，或自动化脚本出个BUG都可能引起主备数据不一致。甚至备库在和主库建立复制关系之前数据就不是一致的，MySQL的逻辑复制并不阻止两个不一致的库建立复制关系。

## 2. 串行化的WAL回放

PG的备库以和主库完全相同顺序串行化的回放WAL日志。

MySQL中由于存在组提交，以及为了解决单线程复制回放慢而采取的并行复制，不得不在复制延迟和数据一致性之前做取舍。
并且这里牵扯到的逻辑很复杂，已经检出了很多的BUG；因为逻辑太复杂了，未来出现新BUG的概率应该相对也不会低。

## 3. 同步复制

PG通过`synchronous_commit`参数设置复制的持久性级别。

下面这些级别越往下越严格，从`remote_write`开始就可以保证单机故障不丢数据了。

- off
- local
- remote_write
- on
- remote_apply

每个级别的含义参考手册:[19.5. 预写式日志](ttp://www.postgres.cn/docs/9.6/runtime-config-wal.html#RUNTIME-CONFIG-WAL-SETTINGS)

MySQL通过半同步复制在很大程度上降低了failover丢失数据的概率。MySQL的主库在等待备库的应答超时时半同步复制会自动降级成异步，此时发生failover会丢失数据。

## 4. 全局唯一的WAL标识

WAL文件头中保存了数据库实例的唯一标识(Database system identifier)，可以确保不同数据库实例产生的WAL可以区别开，同一集群的主备库拥有相同唯一标识。

PG提升备机的时候会同时提升备机的时间线，时间线是WAL文件名的一部分，通过时间线就可以把新主和旧主产生的WAL区别开。
(如果同时提升2个以上的备机，就无法这样区分WAL了，当然这种情况正常不应该发生。)

WAL记录在整个WAL逻辑数据流中的偏移(lsn)作为WAL的标识。

以上3者的联合可唯一标识WAL记录

MySQL5.6开始支持GTID了，这对保障数据一致性是个极大的进步。对于逻辑复制来说，GITD确实做得很棒，但是和PG物理复制的时间线+lsn相比起来就显得太复杂了。时间线+lsn只是2个数字而已；GTID却是一个复杂的集合，而且需要定期清理。

MySQL的GTID是长这样的:

	e6954592-8dba-11e6-af0e-fa163e1cf111:1-5:11-18,
	e6954592-8dba-11e6-af0e-fa163e1cf3f2:1-27


## 5. 数据文件的checksum

在初始化数据库时，使用`-k`选项可以打开数据文件的checksum功能。(建议打开，造成的性能损失很小)
如果底层存储出现问题，可通过checksum及时发现。

	initdb -k $datadir

MySQL也只支持数据文件的checksum，没什么区别。

## 6. WAL记录的checksum

每条WAL记录里都保存了checksum信息，如果WAL的传输存储过程中出现错误可及时发现。

MySQL的binlog记录里也包含checksum，没什么区别。

## 7. WAL文件的验证

WAL可能来自归档的拷贝或人为拷贝，PG在读取WAL文件时会进行验证，可防止DBA弄错文件。

1. 检查WAL文件头中记录的数据库实例的唯一标识是否和本数据库一致
2. 检查WAL页面头中记录的页地址是否正确
3. 其它检查

上面第2项检查的作用主要是应付WAL再利用。

PG在清理不需要的WAL文件时，有2种方式，1是删除，2是改名为未来的WAL文件名防止频繁创建文件。

看下面的例子，`000000030000000000000015`及以后的WAL文件的修改日期比前面的WAL还要老，这些WAL文件就是被重命名了的。

	[postgres@node1 ~]$ ll data1/pg_wal/
	total 213000
	-rw-------. 1 postgres postgres       41 Aug 27 00:53 00000002.history
	-rw-------. 1 postgres postgres 16777216 Sep  1 23:56 000000030000000000000012
	-rw-------. 1 postgres postgres 16777216 Sep  2 11:05 000000030000000000000013
	-rw-------. 1 postgres postgres 16777216 Sep  2 11:05 000000030000000000000014
	-rw-------. 1 postgres postgres 16777216 Aug 27 00:57 000000030000000000000015
	-rw-------. 1 postgres postgres 16777216 Aug 27 00:58 000000030000000000000016
	-rw-------. 1 postgres postgres 16777216 Aug 27 00:59 000000030000000000000017
	-rw-------. 1 postgres postgres 16777216 Aug 27 00:59 000000030000000000000018
	-rw-------. 1 postgres postgres 16777216 Aug 27 00:59 000000030000000000000019
	-rw-------. 1 postgres postgres 16777216 Aug 27 00:59 00000003000000000000001A
	-rw-------. 1 postgres postgres 16777216 Aug 27 00:59 00000003000000000000001B
	-rw-------. 1 postgres postgres 16777216 Aug 27 00:59 00000003000000000000001C
	-rw-------. 1 postgres postgres 16777216 Aug 27 00:59 00000003000000000000001D
	-rw-------. 1 postgres postgres 16777216 Sep  1 23:56 00000003000000000000001E
	-rw-------. 1 postgres postgres       84 Aug 27 01:02 00000003.history
	drwx------. 2 postgres postgres       34 Sep  1 23:56 archive_status

由于有上面的第2项检查，如果读到了这些WAL文件，可以立即识别出来。

	[postgres@node1 ~]$ pg_waldump data1/pg_wal/000000030000000000000015
	pg_waldump: FATAL:  could not find a valid record after 0/15000000


MySQL的binlog文件名一般是长下面这样的，从binlog文件名上看不出任何和GTID的映射关系。

	mysql_bin.000001

不同机器上产生的binlog文件可能同名，如果要管理多套MySQL，千万别拿错文件。因为MySQL是逻辑复制，这些binlog文件就像SQL语句一样，拿到哪里都可以执行。


##　参考

	src/backend/access/transam/xlogreader.c：
	
	static bool
	ValidXLogRecord(XLogReaderState *state, XLogRecord *record, XLogRecPtr recptr)
	{
		pg_crc32c	crc;
	
		/* Calculate the CRC */
		INIT_CRC32C(crc);
		COMP_CRC32C(crc, ((char *) record) + SizeOfXLogRecord, record->xl_tot_len - SizeOfXLogRecord);
		/* include the record header last */
		COMP_CRC32C(crc, (char *) record, offsetof(XLogRecord, xl_crc));
		FIN_CRC32C(crc);
	
		if (!EQ_CRC32C(record->xl_crc, crc))
		{
			report_invalid_record(state,
				   "incorrect resource manager data checksum in record at %X/%X",
								  (uint32) (recptr >> 32), (uint32) recptr);
			return false;
		}
	
		return true;
	}
	...
	static bool
	ValidXLogPageHeader(XLogReaderState *state, XLogRecPtr recptr,
						XLogPageHeader hdr)
	{
	...
			if (state->system_identifier &&
				longhdr->xlp_sysid != state->system_identifier)
			{
				char		fhdrident_str[32];
				char		sysident_str[32];
	
				/*
				 * Format sysids separately to keep platform-dependent format code
				 * out of the translatable message string.
				 */
				snprintf(fhdrident_str, sizeof(fhdrident_str), UINT64_FORMAT,
						 longhdr->xlp_sysid);
				snprintf(sysident_str, sizeof(sysident_str), UINT64_FORMAT,
						 state->system_identifier);
				report_invalid_record(state,
									  "WAL file is from different database system: WAL file database system identifier is %s, pg_control database system identifier is %s",
									  fhdrident_str, sysident_str);
				return false;
			}
	...
		if (hdr->xlp_pageaddr != recaddr)
		{
			char		fname[MAXFNAMELEN];
	
			XLogFileName(fname, state->readPageTLI, segno);
	
			report_invalid_record(state,
						"unexpected pageaddr %X/%X in log segment %s, offset %u",
				  (uint32) (hdr->xlp_pageaddr >> 32), (uint32) hdr->xlp_pageaddr,
								  fname,
								  offset);
			return false;
		}
	...
	}

