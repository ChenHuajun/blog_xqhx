# 如何遏制PostgreSQL WAL的疯狂增长

## 前言

PostgreSQL在写入频繁的场景中，可能会产生大量的WAL日志，而且WAL日志量远远超过实际更新的数据量。
我们可以把这种现象起个名字,叫做“WAL写放大”，造成WAL写放大的主要原因有2点。

1. 在checkpoint之后第一次修改页面，需要在WAL中输出整个page，即全页写(full page writes)。全页写的目的是防止在意外宕机时出现的数据块部分写导致数据库无法恢复。
2. 更新记录时如果新记录位置(ctid)发生变更，索引记录也要相应变更，这个变更也要记入WAL。更严重的是索引记录的变更又有可能导致索引页的全页写，进一步加剧了WAL写放大。

过量的WAL输出会对系统资源造成很大的消耗，因此需要进行适当的优化。

1. 磁盘IO  
	WAL写入是顺序写,通常情况下硬盘对付WAL的顺序写入是绰绰有余的。所以一般可以忽略。

2. 网络IO  
	对局域网内的复制估计还不算问题，远程复制就难说了。

3. 磁盘空间  
	如果做WAL归档，需要的磁盘空间也是巨大的。

## WAL记录的构成

每条WAL记录的构成大致如下：

src/include/access/xlogrecord.h:

	 * The overall layout of an XLOG record is:
	 *		Fixed-size header (XLogRecord struct)
	 *		XLogRecordBlockHeader struct
	 *		XLogRecordBlockHeader struct
	 *		...
	 *		XLogRecordDataHeader[Short|Long] struct
	 *		block data
	 *		block data
	 *		...
	 *		main data

主要占空间是上面的"block data"，再往上的XLogRecordBlockHeader是"block data"的元数据。
一条WAL记录可能不涉及数据块，也可能涉及多个数据块，因此WAL记录中可能没有"block data"也可能有多个"block data"。

"block data"的内容可能是下面几种情况之一

- full page image  
	如果是checkpoint之后第一次修改页面，则输出整个page的内容(即full page image，简称FPI)。但是page中没有数据的hole部分会被排除，如果设置了`wal_compression = on`还会对这page上的数据进行压缩。

- buffer data  
	不需要输出FPI时，就只输出page中指定的数据。

- full page image + buffer data  
	逻辑复制时，即使输出了FPI，也要输出指定的数据。

究竟"block data"中存的是什么内容，通过前面的XLogRecordBlockHeader中的`fork_flags`进行描述。这里的XLogRecordBlockHeader其实也只是个概括的说法，实际上后面还跟了一些其它的Header。完整的结构如下:

	XLogRecordBlockHeader 
	XLogRecordBlockImageHeader (可选，包含FPI时存在）
	XLogRecordBlockCompressHeader (可选，对FPI压缩时存在)
	RelFileNode  (可选，和之前的"block data"的file node不一样时才存在)
	BlockNumber


下面以insert作为例子说明。

src/backend/access/heap/heapam.c:

	Oid
	heap_insert(Relation relation, HeapTuple tup, CommandId cid,
				int options, BulkInsertState bistate)
	{
			...
			xl_heap_insert xlrec;
			xl_heap_header xlhdr;
			...
	
			xlrec.offnum = ItemPointerGetOffsetNumber(&heaptup->t_self);
			...
	
			XLogBeginInsert();
			XLogRegisterData((char *) &xlrec, SizeOfHeapInsert); //1)记录tuple的位置到WAL记录里的"main data"。
	
			xlhdr.t_infomask2 = heaptup->t_data->t_infomask2;
			xlhdr.t_infomask = heaptup->t_data->t_infomask;
			xlhdr.t_hoff = heaptup->t_data->t_hoff;
	
			/*
			 * note we mark xlhdr as belonging to buffer; if XLogInsert decides to
			 * write the whole page to the xlog, we don't need to store
			 * xl_heap_header in the xlog.
			 */
			XLogRegisterBuffer(0, buffer, REGBUF_STANDARD | bufflags);
			XLogRegisterBufData(0, (char *) &xlhdr, SizeOfHeapHeader);//2)记录tuple的head到WAL记录里的"block data"。
			/* PG73FORMAT: write bitmap [+ padding] [+ oid] + data */
			XLogRegisterBufData(0,
								(char *) heaptup->t_data + SizeofHeapTupleHeader,
								heaptup->t_len - SizeofHeapTupleHeader);//3)记录tuple的内容到WAL记录里的"block data"。
			...
	}


### WAL的解析

PostgreSQL的安装目录下有个叫做`pg_xlogdump`的命令可以解析WAL文件，下面看一个例子。

	-bash-4.1$ pg_xlogdump /pgsql/data/pg_xlog/0000000100000555000000D5 -b
	...
	rmgr: Heap        len (rec/tot):     14/   171, tx:  301170263, lsn: 555/D5005080, prev 555/D50030A0, desc: UPDATE off 30 xmax 301170263 ; new off 20 xmax 0
		blkref #0: rel 1663/13269/54349226 fork main blk 1640350
		blkref #1: rel 1663/13269/54349226 fork main blk 1174199
	...


这条WAL记录的解释如下:


- `rmgr: Heap`  
	PostgreSQL内部将WAL日志归类到20多种不同的资源管理器。这条WAL记录所属资源管理器为`Heap`,即堆表。除了`Heap`还有`Btree`,`Transaction`等。
  
- `len (rec/tot):     14/   171`  
	WAL记录的总长度是171字节，其中`main data`部分是14字节(只计数`main data`可能并不合理，本文的后面会有说明)。

- `tx:  301170263`    
	事务号

- `lsn: 555/D5005080`  
	本WAL记录的LSN

- `prev 555/D50030A0`   
	上条WAL记录的LSN

- `desc: UPDATE off 30 xmax 301170263 ; new off 20 xmax 0`   
	这是一条UPDATE类型的记录(每个资源管理器最多包含16种不同的WAL记录类型，)，旧tuple在page中的位置为30(即ctid的后半部分)，新tuple在page中的位置为20。

- `blkref #0: rel 1663/13269/54349226 fork main blk 1640350`  
	引用的第一个page(新tuple所在page)所属的堆表文件为`1663/13269/54349226`,块号为`1640350`(即ctid的前半部分)。通过oid2name可以查到是哪个堆表。

		-bash-4.1$ oid2name -f 54349226
		From database "postgres":
		  Filenode        Table Name
		----------------------------
		  54349226  pgbench_accounts

- `blkref #1: rel 1663/13269/54349226 fork main blk 1174199`  
	引用的第二个page(旧tuple所在page)所属的堆表文件及块号


UPDATE语句除了产生UPDATE类型的WAL记录，实际上还会在前面产生一条LOCK记录，可选的还可能在后面产生若干索引更新的WAL记录。

	-bash-4.1$ pg_xlogdump /pgsql/data/pg_xlog/0000000100000555000000D5 -b
	...
	rmgr: Heap        len (rec/tot):      8/  8135, tx:  301170263, lsn: 555/D50030A0, prev 555/D5001350, desc: LOCK off 30: xid 301170263: flags 0 LOCK_ONLY EXCL_LOCK 
		blkref #0: rel 1663/13269/54349226 fork main blk 1174199 (FPW); hole: offset: 268, length: 116
	
	rmgr: Heap        len (rec/tot):     14/   171, tx:  301170263, lsn: 555/D5005080, prev 555/D50030A0, desc: UPDATE off 30 xmax 301170263 ; new off 20 xmax 0
		blkref #0: rel 1663/13269/54349226 fork main blk 1640350
		blkref #1: rel 1663/13269/54349226 fork main blk 1174199
	...

上面的LOCK记录的例子中，第一个引用page里有`PFW`标识，表示包含FPI，这也是这条WAL记录长度很大的原因。
后面的`hole: offset: 268, length: 116`表示page中包含hole,以及这个hole的偏移位置和长度。
可以算出FPI的大小为8196-116=8080, WAL记录中除FPI以外的数据长度8135-8080=55。



### WAL的统计

PostgreSQL 9.5以后的`pg_xlogdump`都带有统计功能，可以查看不同类型的WAL记录的数量，大小以及FPI的比例。例子如下:

#### postgres.conf配置

下面是一个未经特别优化的配置

	shared_buffers = 32GB
	checkpoint_completion_target = 0.9
	checkpoint_timeout = 5min
	min_wal_size = 1GB
	max_wal_size = 4GB
	full_page_writes = on
	wal_log_hints = on
	wal_level = replica
	wal_keep_segments = 1000

#### 测试

先手动执行checkpoint，再利用pgbench做一个10秒钟的压测

	-bash-4.1$ psql -c "checkpoint;select pg_switch_xlog(),pg_current_xlog_location()"
	 pg_switch_xlog | pg_current_xlog_location 
	----------------+--------------------------
	 556/48000270   | 556/49000000
	(1 row)
	
	-bash-4.1$ pgbench -n -c 64 -j 64 -T 10
	transaction type: <builtin: TPC-B (sort of)>
	scaling factor: 1000
	query mode: simple
	number of clients: 64
	number of threads: 64
	duration: 10 s
	number of transactions actually processed: 123535
	latency average = 5.201 ms
	tps = 12304.460572 (including connections establishing)
	tps = 12317.916235 (excluding connections establishing)
	
	-bash-4.1$ psql -c "select pg_current_xlog_location()"
	 pg_current_xlog_location 
	--------------------------
	 556/B8B40CA0
	(1 row)


#### 日志统计

统计压测期间产生的WAL

	-bash-4.1$ pg_xlogdump --stats=record -s 556/49000000 -e 556/B8B40CA0
	Type                                           N      (%)          Record size      (%)             FPI size      (%)        Combined size      (%)
	----                                           -      ---          -----------      ---             --------      ---        -------------      ---
	XLOG/FPI_FOR_HINT                            650 (  0.06)                15600 (  0.05)              5262532 (  0.29)              5278132 (  0.29)
	Transaction/COMMIT                        123535 ( 11.54)              3953120 ( 11.46)                    0 (  0.00)              3953120 (  0.22)
	CLOG/ZEROPAGE                                  4 (  0.00)                  112 (  0.00)                    0 (  0.00)                  112 (  0.00)
	Standby/RUNNING_XACTS                          2 (  0.00)                  232 (  0.00)                    0 (  0.00)                  232 (  0.00)
	Heap/INSERT                               122781 ( 11.47)              3315087 (  9.61)              1150064 (  0.06)              4465151 (  0.25)
	Heap/UPDATE                               220143 ( 20.57)              8365434 ( 24.24)              1110312 (  0.06)              9475746 (  0.52)
	Heap/HOT_UPDATE                           147169 ( 13.75)              5592422 ( 16.21)               275568 (  0.02)              5867990 (  0.32)
	Heap/LOCK                                 228031 ( 21.31)              7296992 ( 21.15)            975914004 ( 54.70)            983210996 ( 54.06)
	Heap/INSERT+INIT                             754 (  0.07)                20358 (  0.06)                    0 (  0.00)                20358 (  0.00)
	Heap/UPDATE+INIT                            3293 (  0.31)               125134 (  0.36)                    0 (  0.00)               125134 (  0.01)
	Btree/INSERT_LEAF                         223003 ( 20.84)              5798078 ( 16.80)            800409940 ( 44.86)            806208018 ( 44.33)
	Btree/INSERT_UPPER                           433 (  0.04)                11258 (  0.03)                32576 (  0.00)                43834 (  0.00)
	Btree/SPLIT_L                                218 (  0.02)                 6976 (  0.02)                26040 (  0.00)                33016 (  0.00)
	Btree/SPLIT_R                                216 (  0.02)                 6912 (  0.02)                27220 (  0.00)                34132 (  0.00)
	                                        --------                      --------                      --------                      --------
	Total                                    1070232                      34507715 [1.90%]            1784208256 [98.10%]           1818715971 [100%]


这个统计结果显示FPI的比例占到了98.10%。但是这个数据并不准确，因为上面的`Record size`只包含了WAL记录中"main data"的大小，`Combined size`则是"main data"与FPI的合计，漏掉了FPI以外的"block data"。
这是一个Bug，社区正在进行修复，参考[BUG #14687](https://www.postgresql.org/message-id/20170603165939.1436.58887@wrigleys.postgresql.org)

作为临时对策，可以在`pg_xlogdump.c`中新增了一行代码，重新计算`Record size`使之等于WAL总记录长度减去FPI的大小。为便于区分，修改后编译的二进制文件改名为`pg_xlogdump_ex`。

`src/bin/pg_xlogdump/pg_xlogdump.c`：

	fpi_len = 0;
	for (block_id = 0; block_id <= record->max_block_id; block_id++)
	{
		if (XLogRecHasBlockImage(record, block_id))
			fpi_len += record->blocks[block_id].bimg_len;
	}
	rec_len = XLogRecGetTotalLen(record) - fpi_len;/* 新增这一行，重新计算rec_len */


修改后，重新统计WAL的结果如下:

	-bash-4.1$ ./pg_xlogdump_ex --stats=record -s 556/49000000 -e 556/B8B40CA0
	Type                                           N      (%)          Record size      (%)             FPI size      (%)        Combined size      (%)
	----                                           -      ---          -----------      ---             --------      ---        -------------      ---
	XLOG/FPI_FOR_HINT                            650 (  0.06)                31850 (  0.04)              5262532 (  0.29)              5294382 (  0.28)
	Transaction/COMMIT                        123535 ( 11.54)              4200190 (  5.14)                    0 (  0.00)              4200190 (  0.23)
	CLOG/ZEROPAGE                                  4 (  0.00)                  120 (  0.00)                    0 (  0.00)                  120 (  0.00)
	Standby/RUNNING_XACTS                          2 (  0.00)                  236 (  0.00)                    0 (  0.00)                  236 (  0.00)
	Heap/INSERT                               122781 ( 11.47)              9694899 ( 11.86)              1150064 (  0.06)             10844963 (  0.58)
	Heap/UPDATE                               220143 ( 20.57)             29172042 ( 35.67)              1110312 (  0.06)             30282354 (  1.62)
	Heap/HOT_UPDATE                           147169 ( 13.75)             10591360 ( 12.95)               275568 (  0.02)             10866928 (  0.58)
	Heap/LOCK                                 228031 ( 21.31)             12917849 ( 15.80)            975914004 ( 54.70)            988831853 ( 52.99)
	Heap/INSERT+INIT                             754 (  0.07)                59566 (  0.07)                    0 (  0.00)                59566 (  0.00)
	Heap/UPDATE+INIT                            3293 (  0.31)               455778 (  0.56)                    0 (  0.00)               455778 (  0.02)
	Btree/INSERT_LEAF                         223003 ( 20.84)             13080672 ( 16.00)            800409940 ( 44.86)            813490612 ( 43.60)
	Btree/INSERT_UPPER                           433 (  0.04)                31088 (  0.04)                32576 (  0.00)                63664 (  0.00)
	Btree/SPLIT_L                                218 (  0.02)               775610 (  0.95)                26040 (  0.00)               801650 (  0.04)
	Btree/SPLIT_R                                216 (  0.02)               765118 (  0.94)                27220 (  0.00)               792338 (  0.04)
	                                        --------                      --------                      --------                      --------
	Total                                    1070232                      81776378 [4.38%]            1784208256 [95.62%]           1865984634 [100%]


这上面可以看出，有95.62%的WAL空间都被FPI占据了（也就是说WAL至少被放大了20倍)，这个比例是相当高的。


如果不修改`pg_xlogdump`的代码,也可以通过计算WAL距离的方式，算出准确的FPI比例。

	postgres=# select pg_xlog_location_diff('556/B8B40CA0','556/49000000');
	 pg_xlog_location_diff 
	-----------------------
	            1874070688
	(1 row)
	
	postgres=# select 1784208256.0 / 1874070688;
	        ?column?        
	------------------------
	 0.95204960379808256197
	(1 row)


### WAL的优化

在应用的写负载不变的情况下，减少WAL生成量主要有下面几种办法。

1. 延长checkpoint时间间隔  
	FPI产生于checkpoint之后第一次变脏的page，在下次checkpoint到来之前，已经输出过PFI的page是不需要再次输出FPI的。因此checkpoint时间间隔越长，FPI产生的频度会越低。增大`checkpoint_timeout`和`max_wal_size`可以延长checkpoint时间间隔。

2. 增加`HOT_UPDATE`比例  
	普通的`UPDATE`经常需要更新2个数据块，并且可能还要更新索引page，这些又都有可能产生FPI。而`HOT_UPDATE`只修改1个数据块，需要写的WAL量也会相应减少。

3. 压缩  
	PostgreSQL9.5新增加了一个`wal_compression`参数，设为`on`可以对FPI进行压缩，削减WAL的大小。另外还可以在外部通过SSL/SSH的压缩功能减少主备间的通信流量，以及自定义归档脚本对归档的WAL进行压缩。

4. 关闭全页写   
	这是一个立竿见影但也很危险的办法，如果底层的文件系统或储存支持原子写可以考虑。因为很多部署环境都不具备安全的关闭全页写的条件，下文不对该方法做展开。

#### 延长checkpoint时间

首先优化checkpoint相关参数

postgres.conf:

	shared_buffers = 32GB
	checkpoint_completion_target = 0.1
	checkpoint_timeout = 60min
	min_wal_size = 4GB
	max_wal_size = 64GB
	full_page_writes = on
	wal_log_hints = on
	wal_level = replica
	wal_keep_segments = 1000


然后，手工发起一次checkpoint

	-bash-4.1$ psql -c "checkpoint"
	CHECKPOINT


再压测10w个事务，并连续测试10次

	-bash-4.1$ psql -c "select pg_current_xlog_location()"  ; pgbench -n -c 100 -j 100 -t 1000 ;psql -c "select pg_current_xlog_location()"
	 pg_current_xlog_location 
	--------------------------
	 558/47542B08
	(1 row)
	
	transaction type: <builtin: TPC-B (sort of)>
	scaling factor: 1000
	query mode: simple
	number of clients: 100
	number of threads: 100
	number of transactions per client: 1000
	number of transactions actually processed: 100000/100000
	latency average = 7.771 ms
	tps = 12868.123227 (including connections establishing)
	tps = 12896.084970 (excluding connections establishing)
	 pg_current_xlog_location 
	--------------------------
	 558/A13DF908
	(1 row)

测试结果如下

第1次执行

	-bash-4.1$ ./pg_xlogdump_ex --stats=record -s 558/47542B08 -e 558/A13DF908 
	Type                                           N      (%)          Record size      (%)             FPI size      (%)        Combined size      (%)
	----                                           -      ---          -----------      ---             --------      ---        -------------      ---
	XLOG/FPI_FOR_HINT                           1933 (  0.23)                94717 (  0.15)             15612140 (  1.09)             15706857 (  1.05)
	Transaction/COMMIT                        100000 ( 11.89)              3400000 (  5.26)                    0 (  0.00)              3400000 (  0.23)
	CLOG/ZEROPAGE                                  3 (  0.00)                   90 (  0.00)                    0 (  0.00)                   90 (  0.00)
	Standby/RUNNING_XACTS                          1 (  0.00)                  453 (  0.00)                    0 (  0.00)                  453 (  0.00)
	Heap/INSERT                                99357 ( 11.82)              7849103 ( 12.14)                25680 (  0.00)              7874783 (  0.52)
	Heap/UPDATE                               163254 ( 19.42)             22354169 ( 34.58)               351364 (  0.02)             22705533 (  1.51)
	Heap/HOT_UPDATE                           134045 ( 15.94)              9646593 ( 14.92)               384948 (  0.03)             10031541 (  0.67)
	Heap/LOCK                                 172576 ( 20.52)              9800924 ( 15.16)            778259316 ( 54.15)            788060240 ( 52.47)
	Heap/INSERT+INIT                             643 (  0.08)                50797 (  0.08)                    0 (  0.00)                50797 (  0.00)
	Heap/UPDATE+INIT                            2701 (  0.32)               371044 (  0.57)                    0 (  0.00)               371044 (  0.02)
	Btree/INSERT_LEAF                         165561 ( 19.69)              9643359 ( 14.92)            642548940 ( 44.70)            652192299 ( 43.42)
	Btree/INSERT_UPPER                           394 (  0.05)                28236 (  0.04)                56324 (  0.00)                84560 (  0.01)
	Btree/SPLIT_L                                228 (  0.03)               811172 (  1.25)                57280 (  0.00)               868452 (  0.06)
	Btree/SPLIT_R                                168 (  0.02)               595137 (  0.92)                64740 (  0.00)               659877 (  0.04)
	                                        --------                      --------                      --------                      --------
	Total                                     840864                      64645794 [4.30%]            1437360732 [95.70%]           1502006526 [100%]


第5次执行

	-bash-4.1$ ./pg_xlogdump_ex --stats=record -s 559/6312AD98 -e 559/94AC4148
	Type                                           N      (%)          Record size      (%)             FPI size      (%)        Combined size      (%)
	----                                           -      ---          -----------      ---             --------      ---        -------------      ---
	XLOG/FPI_FOR_HINT                           1425 (  0.17)                69825 (  0.11)             11508300 (  1.51)             11578125 (  1.40)
	Transaction/COMMIT                        100000 ( 12.13)              3400000 (  5.37)                    0 (  0.00)              3400000 (  0.41)
	CLOG/ZEROPAGE                                  3 (  0.00)                   90 (  0.00)                    0 (  0.00)                   90 (  0.00)
	Standby/RUNNING_XACTS                          1 (  0.00)                  453 (  0.00)                    0 (  0.00)                  453 (  0.00)
	Heap/INSERT                                99296 ( 12.05)              7844384 ( 12.38)                    0 (  0.00)              7844384 (  0.95)
	Heap/UPDATE                               155408 ( 18.85)             21689908 ( 34.24)                    0 (  0.00)             21689908 (  2.62)
	Heap/HOT_UPDATE                           142042 ( 17.23)             10222825 ( 16.14)                    0 (  0.00)             10222825 (  1.23)
	Heap/LOCK                                 164776 ( 19.99)              9274729 ( 14.64)            608647740 ( 79.60)            617922469 ( 74.63)
	Heap/INSERT+INIT                             704 (  0.09)                55616 (  0.09)                    0 (  0.00)                55616 (  0.01)
	Heap/UPDATE+INIT                            2550 (  0.31)               355951 (  0.56)                    0 (  0.00)               355951 (  0.04)
	Btree/INSERT_LEAF                         157807 ( 19.14)              9886864 ( 15.61)            144491940 ( 18.90)            154378804 ( 18.64)
	Btree/INSERT_UPPER                           151 (  0.02)                10872 (  0.02)                    0 (  0.00)                10872 (  0.00)
	Btree/SPLIT_L                                128 (  0.02)               455424 (  0.72)                    0 (  0.00)               455424 (  0.06)
	Btree/SPLIT_R                                 23 (  0.00)                81466 (  0.13)                    0 (  0.00)                81466 (  0.01)
	                                        --------                      --------                      --------                      --------
	Total                                     824314                      63348407 [7.65%]             764647980 [92.35%]            827996387 [100%]

第10次执行

	-bash-4.1$ ./pg_xlogdump_ex --stats=record -s 55A/3347F298 -e 55A/5420F700
	Type                                           N      (%)          Record size      (%)             FPI size      (%)        Combined size      (%)
	----                                           -      ---          -----------      ---             --------      ---        -------------      ---
	XLOG/FPI_FOR_HINT                           1151 (  0.13)                56399 (  0.09)              9295592 (  1.93)              9351991 (  1.71)
	Transaction/COMMIT                        100000 ( 11.61)              3400000 (  5.15)                    0 (  0.00)              3400000 (  0.62)
	CLOG/ZEROPAGE                                  3 (  0.00)                   90 (  0.00)                    0 (  0.00)                   90 (  0.00)
	Standby/RUNNING_XACTS                          1 (  0.00)                   62 (  0.00)                    0 (  0.00)                   62 (  0.00)
	Heap/INSERT                                99322 ( 11.53)              7846438 ( 11.88)                    0 (  0.00)              7846438 (  1.43)
	Heap/UPDATE                               173901 ( 20.19)             23253149 ( 35.21)                    0 (  0.00)             23253149 (  4.25)
	Heap/HOT_UPDATE                           123452 ( 14.33)              8884888 ( 13.45)                    0 (  0.00)              8884888 (  1.62)
	Heap/LOCK                                 183501 ( 21.30)             10187069 ( 15.43)            449049828 ( 93.22)            459236897 ( 83.84)
	Heap/INSERT+INIT                             678 (  0.08)                53562 (  0.08)                    0 (  0.00)                53562 (  0.01)
	Heap/UPDATE+INIT                            2647 (  0.31)               365259 (  0.55)                    0 (  0.00)               365259 (  0.07)
	Btree/INSERT_LEAF                         176343 ( 20.47)             11251588 ( 17.04)             23338600 (  4.85)             34590188 (  6.32)
	Btree/INSERT_UPPER                           205 (  0.02)                14760 (  0.02)                    0 (  0.00)                14760 (  0.00)
	Btree/SPLIT_L                                172 (  0.02)               611976 (  0.93)                    0 (  0.00)               611976 (  0.11)
	Btree/SPLIT_R                                 33 (  0.00)               116886 (  0.18)                    0 (  0.00)               116886 (  0.02)
	Btree/VACUUM                                   1 (  0.00)                   50 (  0.00)                    0 (  0.00)                   50 (  0.00)
	                                        --------                      --------                      --------                      --------
	Total                                     861410                      66042176 [12.06%]            481684020 [87.94%]            547726196 [100%]


汇总如下:

|No  |tps   |非FPI大小  |WAL总量(字节)|FPI比例(%)|每事务产生的WAL(字节)|
|----|------|----------|------------|---------|---------|
|1   |12896 |64645794  |1502006526  | 95.70   |15020    |
|5   |12896 |63348407  |827996387   | 92.35   |8279     |
|10  |12896 |66042176  |547726196   | 87.94   |5477     |

不难看出非FPI大小是相对固定的，FPI的大小越来越小，这也证实了延长checkpoint间隔对削减WAL大小的作用。


#### 增加`HOT_UPDATE`比例

`HOT_UPDATE`比例过低的一个很常见的原因是更新频繁的表的fillfactor设置不恰当。fillfactor的默认值为100%，可以先将其调整为90%。

对于宽表，要进一步减小fillfactor使得至少可以保留一个tuple的空闲空间。可以查询`pg_class`系统表估算平均tuple大小，并算出合理的fillfactor值。

	postgres=# select 1 - relpages/reltuples max_fillfactor from pg_class where relname='big_tb';
	    max_fillfactor    
	----------------------
	 0.69799901185770750988
	(1 row)

再上面估算出的69%的基础上，可以把fillfactor再稍微设小一点，比如设成65% 。


在前面优化过的参数的基础上，先保持`fillfactor=100`不变，执行100w事务的压测

	-bash-4.1$ psql -c "checkpoint;select pg_current_xlog_location()"  ; pgbench -n -c 100 -j 100 -t 10000 ;psql -c "select pg_current_xlog_location()"
	 pg_current_xlog_location 
	--------------------------
	 55A/66715CC0
	(1 row)
	
	transaction type: <builtin: TPC-B (sort of)>
	scaling factor: 1000
	query mode: simple
	number of clients: 100
	number of threads: 100
	number of transactions per client: 10000
	number of transactions actually processed: 1000000/1000000
	latency average = 7.943 ms
	tps = 12589.895315 (including connections establishing)
	tps = 12592.623734 (excluding connections establishing)
	 pg_current_xlog_location 
	--------------------------
	 55C/7C747F20
	(1 row)

生成的WAL统计如下：

	-bash-4.1$ ./pg_xlogdump_ex --stats=record -s 55A/66715CC0 -e 55C/7C747F20
	Type                                           N      (%)          Record size      (%)             FPI size      (%)        Combined size      (%)
	----                                           -      ---          -----------      ---             --------      ---        -------------      ---
	XLOG/FPI_FOR_HINT                          30699 (  0.36)              1504251 (  0.23)            248063160 (  3.00)            249567411 (  2.80)
	Transaction/COMMIT                       1000000 ( 11.80)             34000000 (  5.15)                    0 (  0.00)             34000000 (  0.38)
	Transaction/COMMIT                             3 (  0.00)                  502 (  0.00)                    0 (  0.00)                  502 (  0.00)
	CLOG/ZEROPAGE                                 31 (  0.00)                  930 (  0.00)                    0 (  0.00)                  930 (  0.00)
	Standby/RUNNING_XACTS                          6 (  0.00)                 2226 (  0.00)                    0 (  0.00)                 2226 (  0.00)
	Standby/INVALIDATIONS                          3 (  0.00)                  414 (  0.00)                    0 (  0.00)                  414 (  0.00)
	Heap/INSERT                               993655 ( 11.72)             78496345 ( 11.90)               135164 (  0.00)             78631509 (  0.88)
	Heap/UPDATE                              1658858 ( 19.57)            225826642 ( 34.23)               455368 (  0.01)            226282010 (  2.54)
	Heap/HOT_UPDATE                          1314890 ( 15.51)             94634083 ( 14.35)               344324 (  0.00)             94978407 (  1.07)
	Heap/LOCK                                1757258 ( 20.73)             98577892 ( 14.94)           5953842520 ( 72.12)           6052420412 ( 67.89)
	Heap/INPLACE                                   9 (  0.00)                 1730 (  0.00)                 6572 (  0.00)                 8302 (  0.00)
	Heap/INSERT+INIT                            6345 (  0.07)               501255 (  0.08)                    0 (  0.00)               501255 (  0.01)
	Heap/UPDATE+INIT                           26265 (  0.31)              3635102 (  0.55)                    0 (  0.00)              3635102 (  0.04)
	Btree/INSERT_LEAF                        1680195 ( 19.82)            104535607 ( 15.85)           2052212660 ( 24.86)           2156748267 ( 24.19)
	Btree/INSERT_UPPER                          4928 (  0.06)               354552 (  0.05)               129128 (  0.00)               483680 (  0.01)
	Btree/SPLIT_L                               4854 (  0.06)             17269109 (  2.62)                22080 (  0.00)             17291189 (  0.19)
	Btree/SPLIT_R                                 95 (  0.00)               336650 (  0.05)                    0 (  0.00)               336650 (  0.00)
	Btree/VACUUM                                   3 (  0.00)                  155 (  0.00)                 2220 (  0.00)                 2375 (  0.00)
	                                        --------                      --------                      --------                      --------
	Total                                    8478097                     659677445 [7.40%]            8255213196 [92.60%]           8914890641 [100%]


设置`fillfactor=90`

	postgres=# alter table pgbench_accounts set (fillfactor=90);
	ALTER TABLE
	postgres=# vacuum full pgbench_accounts;
	VACUUM
	postgres=# alter table pgbench_tellers set (fillfactor=90);
	ALTER TABLE
	postgres=# vacuum full pgbench_tellers;
	VACUUM
	postgres=# alter table pgbench_branches set (fillfactor=90);
	ALTER TABLE
	postgres=# vacuum full pgbench_branches;
	VACUUM

再次测试

	-bash-4.1$ psql -c "checkpoint;select pg_current_xlog_location()"  ; pgbench -n -c 100 -j 100 -t 10000 ;psql -c "select pg_current_xlog_location()"
	 pg_current_xlog_location 
	--------------------------
	 561/78BD2460
	(1 row)
	
	transaction type: <builtin: TPC-B (sort of)>
	scaling factor: 1000
	query mode: simple
	number of clients: 100
	number of threads: 100
	number of transactions per client: 10000
	number of transactions actually processed: 1000000/1000000
	latency average = 7.570 ms
	tps = 13210.665959 (including connections establishing)
	tps = 13212.956814 (excluding connections establishing)
	 pg_current_xlog_location 
	--------------------------
	 562/F91436D8
	(1 row)


生成的WAL统计如下：

	-bash-4.1$ ./pg_xlogdump_ex --stats=record -s 561/78BD2460 -e 562/F91436D8
	Type                                           N      (%)          Record size      (%)             FPI size      (%)        Combined size      (%)
	----                                           -      ---          -----------      ---             --------      ---        -------------      ---
	XLOG/FPI_FOR_HINT                          13529 (  0.22)               662921 (  0.16)             99703804 (  1.66)            100366725 (  1.57)
	Transaction/COMMIT                       1000000 ( 16.09)             34000000 (  8.07)                    0 (  0.00)             34000000 (  0.53)
	Transaction/COMMIT                             4 (  0.00)                 1035 (  0.00)                    0 (  0.00)                 1035 (  0.00)
	CLOG/ZEROPAGE                                 30 (  0.00)                  900 (  0.00)                    0 (  0.00)                  900 (  0.00)
	Standby/RUNNING_XACTS                          5 (  0.00)                 1913 (  0.00)                    0 (  0.00)                 1913 (  0.00)
	Standby/INVALIDATIONS                          2 (  0.00)                  276 (  0.00)                    0 (  0.00)                  276 (  0.00)
	Heap/INSERT                               993629 ( 15.98)             78494191 ( 18.63)               362908 (  0.01)             78857099 (  1.23)
	Heap/DELETE                                    1 (  0.00)                   59 (  0.00)                 7972 (  0.00)                 8031 (  0.00)
	Heap/UPDATE                               553073 (  8.90)             47100570 ( 11.18)                48188 (  0.00)             47148758 (  0.74)
	Heap/HOT_UPDATE                          2438157 ( 39.22)            170238869 ( 40.40)           5809935900 ( 96.97)           5980174769 ( 93.25)
	Heap/LOCK                                 635714 ( 10.23)             34328566 (  8.15)                16200 (  0.00)             34344766 (  0.54)
	Heap/INPLACE                                  10 (  0.00)                 1615 (  0.00)                22692 (  0.00)                24307 (  0.00)
	Heap/INSERT+INIT                            6372 (  0.10)               503388 (  0.12)                    0 (  0.00)               503388 (  0.01)
	Heap/UPDATE+INIT                            8804 (  0.14)               741136 (  0.18)                    0 (  0.00)               741136 (  0.01)
	Btree/INSERT_LEAF                         556456 (  8.95)             35492624 (  8.42)             81089180 (  1.35)            116581804 (  1.82)
	Btree/INSERT_UPPER                          5422 (  0.09)               389735 (  0.09)               328108 (  0.01)               717843 (  0.01)
	Btree/SPLIT_L                               5036 (  0.08)             17918305 (  4.25)               154980 (  0.00)             18073285 (  0.28)
	Btree/SPLIT_R                                414 (  0.01)              1466691 (  0.35)                22140 (  0.00)              1488831 (  0.02)
	Btree/VACUUM                                   2 (  0.00)                  100 (  0.00)                    0 (  0.00)                  100 (  0.00)
	                                        --------                      --------                      --------                      --------
	Total                                    6216660                     421342894 [6.57%]            5991692072 [93.43%]           6413034966 [100%]


设置`fillfactor=90`后，生成的WAL量从8914890641减少到6413034966。

#### 设置WAL压缩

修改postgres.conf，开启WAL压缩

	wal_compression = on

再次测试

	-bash-4.1$ psql -c "checkpoint;select pg_current_xlog_location()"  ; pgbench -n -c 100 -j 100 -t 10000 ;psql -c "select pg_current_xlog_location()"
	 pg_current_xlog_location 
	--------------------------
	 562/F91B5978
	(1 row)
	
	transaction type: <builtin: TPC-B (sort of)>
	scaling factor: 1000
	query mode: simple
	number of clients: 100
	number of threads: 100
	number of transactions per client: 10000
	number of transactions actually processed: 1000000/1000000
	latency average = 8.295 ms
	tps = 12056.091399 (including connections establishing)
	tps = 12059.453725 (excluding connections establishing)
	 pg_current_xlog_location 
	--------------------------
	 563/39880390
	(1 row)


生成的WAL统计如下：

	-bash-4.1$ ./pg_xlogdump_ex --stats=record -s 562/F91B5978 -e 563/39880390
	Type                                           N      (%)          Record size      (%)             FPI size      (%)        Combined size      (%)
	----                                           -      ---          -----------      ---             --------      ---        -------------      ---
	XLOG/FPI_FOR_HINT                           7557 (  0.12)               385375 (  0.09)              5976157 (  0.94)              6361532 (  0.60)
	Transaction/COMMIT                       1000000 ( 15.55)             34000000 (  7.97)                    0 (  0.00)             34000000 (  3.20)
	Transaction/COMMIT                             2 (  0.00)                  356 (  0.00)                    0 (  0.00)                  356 (  0.00)
	CLOG/ZEROPAGE                                 31 (  0.00)                  930 (  0.00)                    0 (  0.00)                  930 (  0.00)
	Standby/RUNNING_XACTS                          5 (  0.00)                 1937 (  0.00)                    0 (  0.00)                 1937 (  0.00)
	Standby/INVALIDATIONS                          4 (  0.00)                  504 (  0.00)                    0 (  0.00)                  504 (  0.00)
	Heap/INSERT                               993632 ( 15.45)             78494714 ( 18.40)               205874 (  0.03)             78700588 (  7.40)
	Heap/UPDATE                               663845 ( 10.32)             56645461 ( 13.28)                39548 (  0.01)             56685009 (  5.33)
	Heap/HOT_UPDATE                          2326238 ( 36.17)            163847160 ( 38.41)            604564022 ( 94.97)            768411182 ( 72.27)
	Heap/LOCK                                 747342 ( 11.62)             40358851 (  9.46)              1713055 (  0.27)             42071906 (  3.96)
	Heap/INPLACE                                   9 (  0.00)                 1425 (  0.00)                 5160 (  0.00)                 6585 (  0.00)
	Heap/INSERT+INIT                            6368 (  0.10)               503072 (  0.12)                    0 (  0.00)               503072 (  0.05)
	Heap/UPDATE+INIT                            9927 (  0.15)               839135 (  0.20)                    0 (  0.00)               839135 (  0.08)
	Btree/INSERT_LEAF                         671387 ( 10.44)             42884429 ( 10.05)             19691394 (  3.09)             62575823 (  5.89)
	Btree/INSERT_UPPER                          2385 (  0.04)               170946 (  0.04)               210384 (  0.03)               381330 (  0.04)
	Btree/SPLIT_L                               1438 (  0.02)              5107876 (  1.20)              2613608 (  0.41)              7721484 (  0.73)
	Btree/SPLIT_R                                947 (  0.01)              3360714 (  0.79)              1563260 (  0.25)              4923974 (  0.46)
	Btree/VACUUM                                   3 (  0.00)                  150 (  0.00)                    0 (  0.00)                  150 (  0.00)
	                                        --------                      --------                      --------                      --------
	Total                                    6431120                     426603035 [40.12%]            636582462 [59.88%]           1063185497 [100%]


设置`wal_compression = on后，生成的WAL量从6413034966减少到1063185497。

#### 优化结果汇总

|`wal_compression`|fillfactor  |tps   |非FPI大小  |WAL总量(字节)|FPI比例(%)|`HOT_UPDATE`比例(%)|每事务产生的WAL(字节)|
|-----------------|------------|------|----------|------------|---------|-------------------|-------------------|
|off              |100         |12592 |659677445 |8255213196  | 92.60   |  44               |8255               |
|off              |90          |13212 |421342894 |6413034966  | 93.43   |  81               |6413               |
|on               |90          |12059 |426603035 |1063185497  | 59.88   |  78               |1063               |

仅仅调整`wal_compression`和fillfactor就削减了87%的WAL，这还没有算上延长checkpoint间隔带来的收益。



### 总结

PostgreSQL在未经优化的情况下，20倍甚至更高的WAL写放大是很常见的，适当的优化之后应该可以减少到3倍以下。引入SSL/SSH压缩或归档压缩等外部手段还可以进一步减少WAL的生成量。

#### 如何判断是否需要优化WAL？

关于如何判断是否需要优化WAL，可以通过分析WAL，然后检查下面的条件，做一个粗略的判断：

- FPI比例高于70%
- `HOT_UPDATE`比例低于70%

以上仅仅是粗略的经验值，仅供参考。并且这个FPI比例可能不适用于低写负载的系统，低写负载的系统FPI比例一定非常高，但是，低写负载系统由于写操作少，因此FPI比例即使高一点也没太大影响。

#### 优化WAL的副作用

前面用到了3种优化手段，如果设置不当，也会产生副作用，具体如下：

1. 延长checkpoint时间间隔  
	导致crash恢复时间变长。crash恢复时需要回放的WAL日志量一般小于`max_wal_size`的一半，WAL回放速度(`wal_compression=on`时)一般是50MB/s~150MB/s之间。可以根据可容忍的最大crash恢复时间（有备机时，切备机可能比等待crash恢复更快），估算出允许的`max_wal_size`的最大值。

2. 调整fillfactor  
	过小的设置会浪费存储空间，这个不难理解。另外，对于频繁更新的表，即使把fillfactor设成100%，每个page里还是要有一部分空间被dead tuple占据，不会比设置一个合适的稍小的fillfactor更节省空间。

3. 设置`wal_compression=on`  
	需要额外占用CPU资源进行压缩，但根据实测的结果影响不大。


#### 其他

去年Uber放出了一篇把PostgreSQL说得一无是处的文章[为什么Uber宣布从PostgreSQL切换到MySQL?](http://www.tuicool.com/articles/Zn2yeuu)给PostgreSQL带来了很大负面影响。Uber文章中提到了PG的几个问题，每一个都被描述成无法逾越的“巨坑”。但实际上这些问题中，除了“写放大”，其它几个问题要么是无关痛痒要么是随着PG的版本升级早就不存在了。至于“写放大”，也是有解的。Uber的文章里没有提到他们在优化WAL写入量上做过什么有益的尝试，并且他们使用的PostgreSQL 9.2也是不支持`wal_compression`的，因此推断他们PG数据库很可能一直运行在20倍以上WAL写放大的完全未优化状态下。


### 参考

- [WAL Reduction](http://www.pgcon.org/2016/schedule/events/947.en.html)
- [也许 MySQL 适合 Uber，但它不一定适合你](http://blog.jobbole.com/111058/)
- [为PostgreSQL讨说法 - 浅析《UBER ENGINEERING SWITCHED FROM POSTGRES TO MYSQL》](https://yq.aliyun.com/articles/58421)

