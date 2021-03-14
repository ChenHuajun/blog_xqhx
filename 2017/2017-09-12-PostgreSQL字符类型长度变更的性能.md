# PostgreSQL字符类型长度变更的性能

## 背景

业务有时会遇到表中的字符型字段的长度不够用的问题，需要修改表定义。但是表里的数据已经很多了，修改字段长度会不会造成应用堵塞呢？

## 测试验证

做了个小测试，如下

建表并插入1000w数据

	postgres=# create table tbx1(id int,c1 char(10),c2 varchar(10));
	CREATE TABLE
	postgres=# insert into tbx1 select id ,'aaaaa','aaaaa' from generate_series(1,10000000) id;
	INSERT 0 10000000

变更varchar类型长度

	postgres=# alter table tbx1 alter COLUMN c2 type varchar(100);
	ALTER TABLE
	Time: 1.873 ms
	postgres=# alter table tbx1 alter COLUMN c2 type varchar(99);
	ALTER TABLE
	Time: 12815.678 ms
	postgres=# alter table tbx1 alter COLUMN c2 type varchar(4);
	ERROR:  value too long for type character varying(4)
	Time: 5.328 ms

变更char类型长度

	postgres=# alter table tbx1 alter COLUMN c1 type char(100);
	ALTER TABLE
	Time: 35429.282 ms
	postgres=# alter table tbx1 alter COLUMN c1 type char(6);
	ALTER TABLE
	Time: 20004.198 ms
	postgres=# alter table tbx1 alter COLUMN c1 type char(4);
	ERROR:  value too long for type character(4)
	Time: 4.671 ms

变更char类型,varchar和text类型互转
	
	alter table tbx1 alter COLUMN c1 type varchar(6);
	ALTER TABLE
	Time: 18880.369 ms
	postgres=# alter table tbx1 alter COLUMN c1 type text;
	ALTER TABLE
	Time: 12.691 ms
	postgres=# alter table tbx1 alter COLUMN c1 type varchar(20);
	ALTER TABLE
	Time: 32846.016 ms
	postgres=# alter table tbx1 alter COLUMN c1 type char(20);
	ALTER TABLE
	Time: 39796.784 ms
	postgres=# alter table tbx1 alter COLUMN c1 type text;
	ALTER TABLE
	Time: 32091.025 ms
	postgres=# alter table tbx1 alter COLUMN c1 type char(20);
	ALTER TABLE
	Time: 26031.344 ms

## 定义变更后的数据

定义变更后，数据位置未变，即没有产生新的tuple

	postgres=# select ctid,id from tbx1 limit 5;
	 ctid  | id 
	-------+----
	 (0,1) |  1
	 (0,2) |  2
	 (0,3) |  3
	 (0,4) |  4
	 (0,5) |  5
	(5 rows)

除varchar扩容以外的定义变更，每个tuple产生一条WAL记录

	$ pg_xlogdump -f -s 3/BE002088 -n 5
	rmgr: Heap        len (rec/tot):      3/   181, tx:       1733, lsn: 3/BE002088, prev 3/BE001FB8, desc: INSERT off 38, blkref #0: rel 1663/13269/16823 blk 58358
	rmgr: Heap        len (rec/tot):      3/   181, tx:       1733, lsn: 3/BE002140, prev 3/BE002088, desc: INSERT off 39, blkref #0: rel 1663/13269/16823 blk 58358
	rmgr: Heap        len (rec/tot):      3/   181, tx:       1733, lsn: 3/BE0021F8, prev 3/BE002140, desc: INSERT off 40, blkref #0: rel 1663/13269/16823 blk 58358
	rmgr: Heap        len (rec/tot):      3/   181, tx:       1733, lsn: 3/BE0022B0, prev 3/BE0021F8, desc: INSERT off 41, blkref #0: rel 1663/13269/16823 blk 58358
	rmgr: Heap        len (rec/tot):      3/   181, tx:       1733, lsn: 3/BE002368, prev 3/BE0022B0, desc: INSERT off 42, blkref #0: rel 1663/13269/16823 blk 58358

## 结论

1. varchar扩容，varchar转text只需修改元数据，毫秒内完成。
2. 其它转换需要的时间和数据量有关，1000w数据10~40秒，但是不改变数据文件，只是做检查。
3. 缩容时如果定义长度不够容纳现有数据报错
4. 不建议使用char类型，除了埋坑几乎没什么用，这一条不仅适用与PG，所有关系数据库应该都适用。
