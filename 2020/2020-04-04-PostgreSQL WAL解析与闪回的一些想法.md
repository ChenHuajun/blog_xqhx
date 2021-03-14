# PostgreSQL WAL解析与闪回的一些想法

## 1. 背景

最近在walminer基础做了不少修改，以支持我们的使用场景。详细参考

- [如何在PostgreSQL故障切换后找回丢失的数据](https://gitee.com/skykiker/XLogMiner/wikis/如何在PostgreSQL故障切换后找回丢失的数据?sort_id=2062372)

修改也花了不少精力和时间，这个过程中有些东西想记录下来，方便以后查阅。

所以，这篇东西有点像流水账。

## 2. WAL文件格式

解析WAL的第一步是要了解WAL的文件格式，我觉得最详细易懂最值得看的资料是下面这个。

- http://www.interdb.jp/pg/pgsql09.html

但是，以上还不够。细节的东西还是要看源码。我主要看的是写WAL记录的地方。

walminer作者李传成的博客里也有不少WAL解析相关的文章，是后来才发现的，我还没有看过。

- https://my.oschina.net/lcc1990


## 3. walminer的解析流程

walminer解析WAL的入口是pg_minerXlog()函数。其主要过程如下

1. 加载数据字典  
2. 起点搜索解析阶段  
	遍历WAL，根据输入的起始时间和起始xid找到匹配的第一个事务。
	这个阶段只解析事务类型的WAL记录，其他WAL记录快速跳过。
3. 完全解析阶段  
	紧接着2的位置，继续往下进行完整的解析。
	这个阶段，会收集所有FPI(FULL PAGE IMAGE)并反映它们的变更，
	还会收集所有DML(insert/update/delete)类型的WAL记录，
	并且在遇到事务提交WAL时输出该事务对应的DML，事务回滚时清空该事务对应的DML。


walminer把WAL记录中tuple变成SQL的过程比较有意思，中间用了一个VALUES的临时格式。

以下面这个UPDATE语句为例

```
update tb1 set c1='3xy' where id=3;
```

其解析过程中涉及到的一些调用点如下：

```
pg_minerXlog()
 ->sqlParser()
  ->XLogMinerRecord()
   ->XLogMinerRecord_heap()
	->minerHeapUpdate(XLogReaderState *record, XLogMinerSQL *sql_simple, uint8 info)
	 1. 获取更新前后的tuple值(字符串格式)
	 ->getTupleInfoByRecord()
	  ->getTupleData_Update()
	   ->mentalTup()
		->mentalTup_nulldata()
		->mentalTup_valuedata()
		 tupleInfo:VALUES(-3, '3x')"
		 tupleInfo_old:VALUES(3, NULL)
		
	 2. 生成中间redo SQL
	 ->getUpdateSQL(sql_simple, tupleInfo, tupleInfo_old,...)
	   sql_simple:UPDATE \"public\".\"tb1\" SET VALUES(3, '3xy') WHERE VALUES(3, '3x')
	   
	 3. 生成中间undo SQL
	 ->getUpdateSQL(&srctl.sql_undo, tupleInfo_old, tupleInfo,...)
	   srctl.sql_undo:UPDATE \"public\".\"tb1\" SET VALUES(3, '3x') WHERE VALUES(-3, '3xy')"

	 4. 生成最终undo SQL
	 将中间中" VALUES"之后部分抹去，从rrctl.values,rrctl.nulls,rrctl.values_old,rrctl.nulls_old重新生成SQL后半部分。
	 ->reAssembleUpdateSql(&srctl.sql_undo,true);
	   srctl.sql_undo:UPDATE "public"."tb1" SET "c1" = '3x' WHERE "id"=3 AND "c1"='3xy' AND ctid = '(0,10)';
	  
   
pg_minerXlog()
 ->sqlParser()
  ->parserUpdateSql()
   4. 生成最终redo SQL
   ->reAssembleUpdateSql(sql_ori, false)
   sql_ori:UPDATE "public"."tb1" SET "c1" = '3xy' WHERE "id"=3 AND "c1"='3x';

```

## 4. walminer存在的问题

walminer是个非常棒的工具，填补了PG的一个空白。
但是，在我们准备把它推向生产时发现了一些问题。

1. 资源消耗和解析速度
	- 粗测了一下，解析一个16MB的WAL文件大概需要15秒。不得不说实在太慢了。
	- 解析大量WAL文件还容易把内存撑爆。
2. 正确性和可靠性
	- 对并发事务产生的WAL记录，解析的结果不对。
	- 缺少回归测试集
	- 其他的小问题
3. 易用性
	- 不支持基于LSN位置的过滤
	- 解析一次WAL要调用好几个函数，我觉得没有必要，一个就够了。


对这些已知的问题，都进行了改进。主要有下面几点

1. 使用单个wal2sql()函数执行WAL解析任务
2. 支持指定起始和结束LSN位置过滤事务
3. 支持从WAL记录的old tuple或old key tuple中解析old元组构造where条件
4. 增加lsn和commit_end_lsn结果输出字段
5. 添加FPI(FULL PAGE IMAGE)解析开关，默认关闭image解析
6. 优化WAL解析速度，大约提升10倍
7. 给定LSN起始位置后，支持根据WAL文件名筛选，避免大量冗余的文件读取。
8. 修复多个解析BUG
9. 增加回归测试集
10.合并PG10/11/12支持到一个分支


修改后的walminer参考

https://gitee.com/skykiker/XLogMiner

后续希望这些修改能合到源库里。


## 5. 后续改进思路

walminer在功能和使用场景上和MySQL的binlog2sql是非常接近的。

binlog2sql对自己的场景描述如下：

https://github.com/danfengcao/binlog2sql
- 数据快速回滚(闪回)
- 主从切换后新master丢数据的修复
- 从binlog生成标准SQL，带来的衍生功能

binlog2sql已经有很多生产部署的案例，但是walminer好像还没有。
其中原因，我想除了修改版已经解决的那些问题，walminer作为闪回工具，还有进一步改进的空间。

我考虑主要有以下几点可以改进的
1. 以fdw的形式提供接口  
    和函数相比fdw的好处是明显的
    - 不需要等所有WAL都解析完了再输出，因此可以结合limit进行多次快速探测
    - 不需要创建临时表，解析过程中不需要产生WAL（产生WAL可能会触发WAL清理）。
    - 可以在备库执行  
    使用fdw后，过滤条件直接通过where条件传递，接口更清晰。无法通过where条件传递东西，比如WAL存储目录，可以通过设置参数解决。
2. 把解析过程分成事务匹配探测和完全解析2个部分  
    完全解析时，需要从匹配的事务往前回溯一部分，确保该事务的SQL甚至所需FPI都被解析到。
    单纯从匹配的事务后面开始完全解析，会丢失SQL的。
3. 增加DDL解析  
    其实并不需要解析出完整的DDL和逆向的闪回DDL，这个任务也很难实现。
    只需要能知道什么时间，在WAL的哪个位点，哪个表发生了定义变更即可。
4. 代码重构  
    从性能和可维护性考虑，有必要进行代码重构。
5. 工具命名  
    既然这个工具的功能是从WAL中解析出原始SQL和undo SQL，walminer这个名称就显得不合适了。
    因为从字面上理解，walminer应该是解析WAL本身包含的信息，包括很多与SQL无关的的信息，
    但是不应该包含undo SQL这种WAL里没有而完全是被构造出来的东西。
    所以，既然聚焦的功能是从WAL中提取SQL，这个东西可以叫wal2sql。就像MySQL的binlog2sql一样更加直观。
    

## 6. 参考

- [不同数据库间的闪回方案对比](https://www.modb.pro/db/22169)
- [PostgreSQL Oracle 兼容性之 - 事件触发器实现类似Oracle的回收站功能](https://github.com/digoal/blog/blob/master/201504/20150429_01.md?spm=a2c4e.10696291.0.0.5d3119a4ZrkOdK&file=20150429_01.md)
- [PostgreSQL flashback(闪回) 功能实现与介绍](https://yq.aliyun.com/articles/228267)
- [MySQL Flashback 工具介绍](https://www.cnblogs.com/DataArt/p/9873365.html)
- [MySQL闪回方案讨论及实现](https://www.iteye.com/blog/dinglin-1539167)

