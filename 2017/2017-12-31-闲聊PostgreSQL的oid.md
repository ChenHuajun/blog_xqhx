# 闲聊PostgreSQL的oid

## oid为何物?

PostgreSQL的系统表中大多包含一个叫做OID的隐藏字段，这个OID也是这些系统表的主键。

所谓OID，中文全称就是"对象标识符"。what？还有“对象”?

如果对PostgreSQL有一定了解，应该知道PostgreSQL最初的设计理念就是"对象关系数据库"。也就是说，系统表中储存的那些元数据，比如表，视图，类型，操作符，函数，索引，FDW，甚至存储过程语言等等这些统统都是对象。具体表现就在于这些东西都可以扩展，可以定制。不仅如此，PostgreSQL还支持函数重载，表继承等这些很OO的特性。

利用PostgreSQL的这些特性，用户可以根据业务场景从应用层到数据库层做一体化的优化设计，获得极致的性能与用户体验。一些用惯了MySQL的互联网架构师推崇"把数据库当存储"，这一设计准则用在MySQL上也许合适，但如果硬要套在PostgreSQL上，就有点暴殄天物了！

扯得有点远了^_^，下面举几个栗子看下oid长啥样。

## 使用示例

先随便创建一张表

	postgres=# create table tb1(id int);
	CREATE TABLE

再看下这张表对应的oid

	postgres=# select oid from pg_class where relname='tb1';
	  oid  
	-------
	 32894
	(1 row)

这个oid是隐藏字段，因此必须在select列表里明确指定oid列名，光使用`select *`是不输出oid的。

	postgres=# select *from pg_class where relname='tb1';
	-[ RECORD 1 ]-------+------
	relname             | tb1
	relnamespace        | 2200
	reltype             | 32896
	reloftype           | 0
	relowner            | 10
	relam               | 0
	relfilenode         | 32894
	reltablespace       | 0
	relpages            | 0
	reltuples           | 0
	relallvisible       | 0
	reltoastrelid       | 32897
	relhasindex         | f
	relisshared         | f
	relpersistence      | p
	relkind             | r
	relnatts            | 2
	relchecks           | 0
	relhasoids          | f
	relhaspkey          | f
	relhasrules         | f
	relhastriggers      | f
	relhassubclass      | f
	relrowsecurity      | f
	relforcerowsecurity | f
	relispopulated      | t
	relreplident        | d
	relispartition      | f
	relfrozenxid        | 596
	relminmxid          | 2
	relacl              | 
	reloptions          | 
	relpartbound        |

不同对象对应于不同的对象标识符类型，比如表对象对应的对象标识符类型就是`regclass`，
通过对象标识符类型可以实现，对象标识符的数字值和对象名称之间的自由转换。

比如，上面那条SQL可以改写成以下的形式。

	postgres=# select 'tb1'::regclass::int;
	 int4  
	-------
	 32894
	(1 row)

反过来当然也是可以的，在PostgreSQL里就是一个普通的类型转换。

	postgres=# select 32894::regclass;
	 regclass 
	----------
	 tb1
	(1 row)

## 表的数据类型

作为OO的体现之一，PostgreSQL中每个表都是一个新的数据类型，即有一个相应的数据类型对象。

通过`pg_class`可以查出刚才创建的表对应的数据类型对象的oid

	postgres=# select reltype from pg_class where relname='tb1';
	 reltype 
	---------
	   32896
	(1 row)

在定义数据类型的系统表`pg_type`中保存了这个类型相关的信息。

	postgres=# select * from pg_type where oid=32896;
	-[ RECORD 1 ]--+------------
	typname        | tb1
	typnamespace   | 2200
	typowner       | 10
	typlen         | -1
	typbyval       | f
	typtype        | c
	typcategory    | C
	typispreferred | f
	typisdefined   | t
	typdelim       | ,
	typrelid       | 32894
	typelem        | 0
	typarray       | 32895
	typinput       | record_in
	typoutput      | record_out
	typreceive     | record_recv
	typsend        | record_send
	typmodin       | -
	typmodout      | -
	typanalyze     | -
	typalign       | d
	typstorage     | x
	typnotnull     | f
	typbasetype    | 0
	typtypmod      | -1
	typndims       | 0
	typcollation   | 0
	typdefaultbin  | 
	typdefault     | 
	typacl         | 


数据类型的对象标识符类型是regtype，通过regtype转换可以看到新创建的数据类型对象的名字也叫`tb1`。

	postgres=# select 32896::regtype;
	 regtype 
	---------
	 tb1
	(1 row)

`tb1`类型在使用上和内置的int,text这些常见的数据类型几乎没有区别。

所以，你可以把一个字符串的值转换成`tb1`类型。

	postgres=# select $$(999,'abcd')$$::text::tb1;
	     tb1      
	--------------
	 (999,'abcd')
	(1 row)

可以使用`.`取出表类型里面的1个或所有字段

	postgres=# select ($$(999,'abcd')$$::text::tb1).id;
	 id  
	-----
	 999
	(1 row)

	postgres=# select ($$(999,'abcd')$$::text::tb1).*;
	 id  |   c1   
	-----+--------
	 999 | 'abcd'
	(1 row)

当然，还可以用这个类型去创建新的表

	postgres=# create table tb2(id int, c1 tb1);
	CREATE TABLE

如果你其实是想要创建一个像表一样的数据类型(即多个字段的组合)，也可以单独创建这个数据类型。
'g，
	postgres=# create type ty1 as (id int,c1 text);
	CREATE TYPE

## 表文件

每个表的数据存储在文件系统中单独的文件中(实际不止一个文件)，文件路径可以通过系统函数查询

	postgres=# select pg_relation_filepath('tb1');
	 pg_relation_filepath 
	----------------------
	 base/13211/32894
	(1 row)

上面的`base`对应的是缺省表空间，除此以外还有global表空间。

	postgres=# select oid,* from pg_tablespace ;
	 oid  |  spcname   | spcowner | spcacl | spcoptions 
	------+------------+----------+--------+------------
	 1663 | pg_default |       10 |        | 
	 1664 | pg_global  |       10 |        | 
	(2 rows)

用户等全局对象存储在global表空间

	postgres=# select relname,reltablespace from pg_class where relkind='r' and reltablespace<>0;
	        relname        | reltablespace 
	-----------------------+---------------
	 pg_authid             |          1664
	 pg_subscription       |          1664
	 pg_database           |          1664
	 pg_db_role_setting    |          1664
	 pg_tablespace         |          1664
	 pg_pltemplate         |          1664
	 pg_auth_members       |          1664
	 pg_shdepend           |          1664
	 pg_shdescription      |          1664
	 pg_replication_origin |          1664
	 pg_shseclabel         |          1664
	(11 rows)

表文件路径的第2部分13211是表所在数据库的oid

	postgres=# select oid,datname from pg_database;
	  oid  |  datname  
	-------+-----------
	 13211 | postgres
	     1 | template1
	 13210 | template0
	(3 rows)

第3部分就是表对象的oid。

## oid如何分配?

oid的分配来自一个实例的全局变量，每分配一个新的对象，对这个全局变量加一。
当分配的oid超过4字节整形最大值的时候会重新从0开始分配，但这并不会导致类似于事务ID回卷那样严重的影响。

系统表一般会以oid作为主键，分配oid时,PostgreSQL会通过主键索引检查新的oid是否在相应的系统表中已经存在，
如果存在则尝试下一个oid。

相关代码如下:

	Oid
	GetNewOidWithIndex(Relation relation, Oid indexId, AttrNumber oidcolumn)
	{
		Oid			newOid;
		SnapshotData SnapshotDirty;
		SysScanDesc scan;
		ScanKeyData key;
		bool		collides;
	
		InitDirtySnapshot(SnapshotDirty);
	
		/* Generate new OIDs until we find one not in the table */
		do
		{
			CHECK_FOR_INTERRUPTS();
	
			newOid = GetNewObjectId();
	
			ScanKeyInit(&key,
						oidcolumn,
						BTEqualStrategyNumber, F_OIDEQ,
						ObjectIdGetDatum(newOid));
	
			/* see notes above about using SnapshotDirty */
			scan = systable_beginscan(relation, indexId, true,
									  &SnapshotDirty, 1, &key);
	
			collides = HeapTupleIsValid(systable_getnext(scan));
	
			systable_endscan(scan);
		} while (collides);
	
		return newOid;
	}

因此，oid溢出不会导致系统表中出现oid冲突(2个不同的系统表可能存在oid相同的对象)。
但重试毕竟会使分配有效的oid花费较多的时间，因此不建议用户为普通的用户表使用oid(使用`with oids`)从而导致oid过早的耗尽。
而且，使用oid的用户表如果未给oid创建唯一索引，oid溢出时，可能这个用户表中可能出现重复oid。以下是一个简单的演示:

创建一个`with oids`的表，并插入2条记录

	postgres=# create table tb3(id int) with oids;
	CREATE TABLE
	postgres=# insert into tb3 values(1);
	INSERT 32912 1
	postgres=# insert into tb3 values(2);
	INSERT 32913 1

此时，下一个全局oid是32914

	[postgres@node1 ~]$ pg_ctl -D data stop
	waiting for server to shut down.... done
	server stopped
	[postgres@node1 ~]$ pg_controldata data
	pg_control version number:            1002
	Catalog version number:               201707211
	Database system identifier:           6500386650559491472
	Database cluster state:               shut down
	pg_control last modified:             Sun 07 Jan 2018 11:14:58 PM CST
	Latest checkpoint location:           0/9088930
	Prior checkpoint location:            0/9073988
	Latest checkpoint's REDO location:    0/9088930
	Latest checkpoint's REDO WAL file:    000000010000000000000009
	Latest checkpoint's TimeLineID:       1
	Latest checkpoint's PrevTimeLineID:   1
	Latest checkpoint's full_page_writes: on
	Latest checkpoint's NextXID:          0:602
	Latest checkpoint's NextOID:          32914
	Latest checkpoint's NextMultiXactId:  2
	Latest checkpoint's NextMultiOffset:  3
	Latest checkpoint's oldestXID:        548
	Latest checkpoint's oldestXID's DB:   1
	Latest checkpoint's oldestActiveXID:  0
	Latest checkpoint's oldestMultiXid:   1
	Latest checkpoint's oldestMulti's DB: 1
	Latest checkpoint's oldestCommitTsXid:0
	Latest checkpoint's newestCommitTsXid:0
	Time of latest checkpoint:            Sun 07 Jan 2018 11:14:58 PM CST
	Fake LSN counter for unlogged rels:   0/1
	Minimum recovery ending location:     0/0
	Min recovery ending loc's timeline:   0
	Backup start location:                0/0
	Backup end location:                  0/0
	End-of-backup record required:        no
	wal_level setting:                    replica
	wal_log_hints setting:                off
	max_connections setting:              100
	max_worker_processes setting:         8
	max_prepared_xacts setting:           0
	max_locks_per_xact setting:           64
	track_commit_timestamp setting:       off
	Maximum data alignment:               8
	Database block size:                  8192
	Blocks per segment of large relation: 131072
	WAL block size:                       8192
	Bytes per WAL segment:                16777216
	Maximum length of identifiers:        64
	Maximum columns in an index:          32
	Maximum size of a TOAST chunk:        1996
	Size of a large-object chunk:         2048
	Date/time type storage:               64-bit integers
	Float4 argument passing:              by value
	Float8 argument passing:              by value
	Data page checksum version:           0
	Mock authentication nonce:            5b060aed93e061d3d1ad2dccdfe3336b1ac844f94872e068d86587c48c7d394a


篡改下一个全局oid为32912

	[postgres@node1 ~]$ pg_resetwal -D data -o 32912
	Write-ahead log reset
	[postgres@node1 ~]$ pg_ctl -D data start

再插入3条记录，oid存在重复分配。

	postgres=# insert into tb3 values(3);
	INSERT 32912 1
	postgres=# insert into tb3 values(4);
	INSERT 32913 1
	postgres=# insert into tb3 values(5);
	INSERT 32914 1
	postgres=# select oid,* from tb3;
	  oid  | id 
	-------+----
	 32912 |  1
	 32913 |  2
	 32912 |  3
	 32913 |  4
	 32914 |  5
	(5 rows)

