# 如何在PostgreSQL故障切换后找回丢失的数据

## 1. 背景

PostgreSQL的HA方案一般都基于其原生的流复制技术，支持同步复制和异步复制模式。
同步复制模式虽然可以最大程度保证数据不丢失，但通常需要至少部署三台机器，确保有两台以上的备节点。
因此很多一主一备HA集群，都是使用异步复制。

在异步复制下，主库宕机，把备节点切换为新的主节点后，可能会丢失最近更新的少量数据。
如果这些丢失的数据对业务比较重要，那么，能不能从数据库里找回来呢?

下面就介绍找回这些数据的方法

## 2. 原理

基本过程
1. 备库被提升为新主后会产生一个新的时间线，这个新时间线的起点我们称之为分叉点。
2. 旧主故障修复后，在旧主上从分叉点位置开始解析WAL文件，将所有已提交事务产生的数据变更解析成SQL。
    前提是旧主磁盘没有损坏，能够正常启动。不过，生产最常见的故障是物理机宕机，一般重启机器就可以恢复。
3. 业务拿到这些SQL，人工确认后，回补数据。

为了能从WAL记录解析出完整的SQL，最好`wal_level`设置成logical，并且表上有主键。
此时，对于我们关注的增删改DML语句，WAL记录中包含了足够的信息，能够把数据变更还原成SQL。
详细如下：

- INSERT  
WAL记录中包含了完整的tuple数据，结合系统表中表定义可以还原出SQL。

- UPDATE  
WAL记录中包含了完整的更新后的tuple数据，对于更新前的tuple，视以下情况而定。

    - 表设置了replica identity full属性   
        WAL记录中包含完整的更新前的tuple数据
    - 表包含replica identity key(或主键)且replica identity key的值发生了变更    
        WAL记录中包含了更新前的tuple的replica identity key(或主键)的字段值
    - 其他   
        WAL记录中不包含更新前的tuple数据
    
- DELETE  
WAL记录中可能包含被删除的tuple信息，视以下情况而定。

    - 表设置了replica identity full属性    
        WAL记录中包含完整的被删除的tuple数据
    - 表包含replica identity key(或主键)    
        WAL记录中包含被删除的tuple的replica identity key(或主键)的字段值
    - 其他
        WAL记录中不包含被删除的tuple数据    


如果`wal_level`不是logical或表上没有主键，还可以从WAL中的历史FPI(FULL PAGE IANGE)中解析出变更前tuple。

因此，原理上，从WAL解析出SQL是完全可行的。并且也已经有开源工具可以支持这项工作了。


## 3. 工具

使用改版的walminer工具解析WAL文件。

- https://gitee.com/skykiker/XLogMiner

walminer是一款很不错的工具，可以从WAL文件中解析出原始SQL和undo SQL。
但是当前原生的walminer要支持这一场景还存在一些问题，并且解析WAL文件的速度非常慢。

改版的walminer分支增加了基于LSN位置的解析功能，同时修复了一些BUG，解析WAL文件的速度也提升了大约10倍。
其中的部分修改后续希望能合到walminer主分支里。


## 3. 前提条件

1. 分叉点之后的WAL日志文件未被清除  
	正常是足够的。也可以设置合理的`wal_keep_segments`参数，在`pg_wal`目录多保留一些WAL。比如:
	```
	wal_keep_segments=100
	```
	如果配置了WAL归档，也可以使用归档目录中的WAL。
2. WAL日志级别设置为logical
	```
	wal_level=logical
	```
3. 表有主键或设置了replica identity key/replica identity full
4. 分叉点之后表定义没有发生变更


注:以上条件的2和3如果不满足其实也可以支持，但是需要保留并解析分叉点的前一个checkpint以后的所有WAL。

## 4. 使用演示

### 4.1 环境准备

搭建好一主一备异步复制的HA集群

机器:
- node1(主)
- node2(备)

软件:
- PostgreSQL 10

参数:
```
wal_level=logical
```

### 4.2 安装walminer插件

从以下位置下载改版walminer插件源码

- https://gitee.com/skykiker/XLogMiner/

在主备库分别安装walminer

```
cd walminer
make && make install
```

在主库创建walminer扩展

```
create extension walminer
```


### 4.3 创建测试表

```
create table tb1(id int primary key, c1 text);
insert into tb1 select id,'xxx' from generate_series(1,10000) id;
```

### 4.4 模拟业务负载

准备测试脚本

test.sql
```
\set id1 random(1,10000)
\set id2 random(1,10000)

insert into tb1 values(:id1,'yyy') on conflict (id)
  do update set c1=excluded.c1;

delete from tb1 where id=:id2;
```

在主库执行测试脚本模拟业务负载

```
pgbench -c 8 -j 8 -T 1000 -f test.sql
```

### 4.5 模拟主库宕机

在主库强杀PG进程

```
killall -9 postgres
```

### 4.6 备库提升为新主

在备库执行提升操作

```
pg_ctl promote
```

查看切换时的时间线分叉点

```
[postgres@host2 ~]$tail -1 /pgsql/data10/pg_wal/00000002.history
1	0/EF76440	no recovery target specified
```

### 4.7 在旧主库找回丢失的数据

启动旧主库后调用wal2sql()函数，找回分叉点以后旧主库上已提交事务执行的所有SQL。

```
postgres=# select xid,timestamptz,op_text from wal2sql(NULL,'0/EF76440') ;
NOTICE:  Get data dictionary from current database.
NOTICE:  Wal file "/pgsql/data10/pg_wal/00000001000000000000000F" is not match with datadictionary.
NOTICE:  Change Wal Segment To:/pgsql/data10/pg_wal/00000001000000000000000C
NOTICE:  Change Wal Segment To:/pgsql/data10/pg_wal/00000001000000000000000D
NOTICE:  Change Wal Segment To:/pgsql/data10/pg_wal/00000001000000000000000E
  xid   |          timestamptz          |                           op_text                           
--------+-------------------------------+-------------------------------------------------------------
 938883 | 2020-03-31 17:12:10.331487+08 | DELETE FROM "public"."tb1" WHERE "id"=7630;
 938884 | 2020-03-31 17:12:10.33149+08  | INSERT INTO "public"."tb1"("id", "c1") VALUES(5783, 'yyy');
 938885 | 2020-03-31 17:12:10.331521+08 | DELETE FROM "public"."tb1" WHERE "id"=3559;
 938886 | 2020-03-31 17:12:10.331586+08 | UPDATE "public"."tb1" SET "c1" = 'yyy' WHERE "id"=7585;
 938887 | 2020-03-31 17:12:10.331615+08 | UPDATE "public"."tb1" SET "c1" = 'yyy' WHERE "id"=973;
 938888 | 2020-03-31 17:12:10.331718+08 | INSERT INTO "public"."tb1"("id", "c1") VALUES(7930, 'yyy');
 938889 | 2020-03-31 17:12:10.33173+08  | UPDATE "public"."tb1" SET "c1" = 'yyy' WHERE "id"=1065;
 938890 | 2020-03-31 17:12:10.331741+08 | INSERT INTO "public"."tb1"("id", "c1") VALUES(2627, 'yyy');
 938891 | 2020-03-31 17:12:10.331766+08 | UPDATE "public"."tb1" SET "c1" = 'yyy' WHERE "id"=1012;
 938892 | 2020-03-31 17:12:10.33178+08  | INSERT INTO "public"."tb1"("id", "c1") VALUES(4740, 'yyy');
 938893 | 2020-03-31 17:12:10.331814+08 | DELETE FROM "public"."tb1" WHERE "id"=4275;
 938894 | 2020-03-31 17:12:10.331892+08 | UPDATE "public"."tb1" SET "c1" = 'yyy' WHERE "id"=8651;
 938895 | 2020-03-31 17:12:10.33194+08  | UPDATE "public"."tb1" SET "c1" = 'yyy' WHERE "id"=9313;
 938896 | 2020-03-31 17:12:10.331967+08 | DELETE FROM "public"."tb1" WHERE "id"=3251;
 938897 | 2020-03-31 17:12:10.332001+08 | DELETE FROM "public"."tb1" WHERE "id"=2968;
 938898 | 2020-03-31 17:12:10.332025+08 | INSERT INTO "public"."tb1"("id", "c1") VALUES(5331, 'yyy');
 938899 | 2020-03-31 17:12:10.332042+08 | UPDATE "public"."tb1" SET "c1" = 'yyy' WHERE "id"=3772;
 938900 | 2020-03-31 17:12:10.332048+08 | INSERT INTO "public"."tb1"("id", "c1") VALUES(94, 'yyy');
(18 rows)

Time: 2043.380 ms (00:02.043)
```

上面wal2sql()的输出结果是按事务在WAL中提交的顺序排序的。可以把这些SQL导到文件里提供给业务修单。

###  4.8 恢复旧主

可以通过`pg_rewind`快速回退旧主多出的数据，然后作为新主的备库重建复制关系，恢复HA。


## 5. 小结

借助改版的walminer，可以方便快速地在PostgreSQL故障切换后找回丢失的数据。

walminer除了能生成正向SQL，还可以生成逆向的undo SQL，也就是我们熟知的闪回功能。
undo SQL的生成方法和使用限制可以参考开源项目文档。

然而，在作为闪回功能使用时，walminer还有需要进一步改进的地方，最明显的就是解析速度。
因为从WAL记录中完整解析undo SQL需要开启replica identity full，而很多系统可能不会为每个表都打开replica identity full设置。
在没有replica identity full的前提下，生成undo SQL就必须要依赖历史FPI。

虽然改版的walminer已经在解析速度上提升了很多倍，但是如果面对几十GB的WAL文件，解析并收集历史所有FPI，资源和时间消耗仍然是个不小的问题。




