# PostgreSQL执行计划走偏常见案例之二多Join条件组合



## 1. 前言

Join是基本的SQL功能，Join行估算偏差导致优化器采用糟糕执行计划也是很普遍的事情。



## 2. 示例

数据准备：

```
create table tb1(c1 int,c2 int,d int);
create table tb2(c1 int,c2 int);
create table tb3(d int);
create index on tb3(d);

insert into tb1 select id, id, id/100 from generate_series(1,100000)id;
insert into tb2 select id, id from generate_series(1,100000)id;
insert into tb3 select id from generate_series(1,1000)id;
```



查询SQL：

```
select count(*) from tb1,tb2,tb3
  where tb1.c1=tb2.c1 and tb1.c2=tb2.c2
        and tb1.d=tb3.d
```



执行计划：

```
postgres=# explain analyze
postgres-# select count(*) from tb1,tb2,tb3
postgres-# where tb1.c1=tb2.c1 and tb1.c2=tb2.c2
postgres-#       and tb1.d=tb3.d;
                                                            QUERY PLAN
----------------------------------------------------------------------------------------------------------------------------------
 Aggregate  (cost=7021.51..7021.52 rows=1 width=8) (actual time=18448.825..18448.828 rows=1 loops=1)
   ->  Nested Loop  (cost=3334.00..7021.51 rows=1 width=0) (actual time=38.280..18436.881 rows=99901 loops=1)
         Join Filter: (tb1.d = tb3.d)
         Rows Removed by Join Filter: 99900099
         ->  Hash Join  (cost=3334.00..6994.01 rows=1 width=4) (actual time=29.513..155.524 rows=100000 loops=1)
               Hash Cond: ((tb1.c1 = tb2.c1) AND (tb1.c2 = tb2.c2))
               ->  Seq Scan on tb1  (cost=0.00..1541.00 rows=100000 width=12) (actual time=0.006..10.360 rows=100000 loops=1)
               ->  Hash  (cost=1443.00..1443.00 rows=100000 width=8) (actual time=29.408..29.409 rows=100000 loops=1)
                     Buckets: 131072  Batches: 2  Memory Usage: 2982kB
                     ->  Seq Scan on tb2  (cost=0.00..1443.00 rows=100000 width=8) (actual time=0.005..7.975 rows=100000 loops=1)
         ->  Seq Scan on tb3  (cost=0.00..15.00 rows=1000 width=4) (actual time=0.003..0.077 rows=1000 loops=100000)
 Planning Time: 0.166 ms
 Execution Time: 18448.880 ms
(13 rows)
```

这个执行计划通过nestloop JOIN对tb3做了10w次全表扫描，非常耗时，花了18448ms。



## 3. 分析

如果禁用nestloop JOIN，强制走hash Join执行时间只有128ms，但是hash join的估算代价比nestloop高了0.02(7021.54 - 7021.52),没有被选中。

```
postgres=# set enable_nestloop =off;
SET
postgres=# explain analyze
select count(*) from tb1,tb2,tb3
where tb1.c1=tb2.c1 and tb1.c2=tb2.c2
      and tb1.d=tb3.d;
                                                            QUERY PLAN
----------------------------------------------------------------------------------------------------------------------------------
 Aggregate  (cost=7021.53..7021.54 rows=1 width=8) (actual time=128.421..128.424 rows=1 loops=1)
   ->  Hash Join  (cost=3361.50..7021.52 rows=1 width=0) (actual time=29.536..120.834 rows=99901 loops=1)
         Hash Cond: (tb1.d = tb3.d)
         ->  Hash Join  (cost=3334.00..6994.01 rows=1 width=4) (actual time=29.094..97.944 rows=100000 loops=1)
               Hash Cond: ((tb1.c1 = tb2.c1) AND (tb1.c2 = tb2.c2))
               ->  Seq Scan on tb1  (cost=0.00..1541.00 rows=100000 width=12) (actual time=0.004..8.191 rows=100000 loops=1)
               ->  Hash  (cost=1443.00..1443.00 rows=100000 width=8) (actual time=28.936..28.936 rows=100000 loops=1)
                     Buckets: 131072  Batches: 2  Memory Usage: 2982kB
                     ->  Seq Scan on tb2  (cost=0.00..1443.00 rows=100000 width=8) (actual time=0.007..8.102 rows=100000 loops=1)
         ->  Hash  (cost=15.00..15.00 rows=1000 width=4) (actual time=0.217..0.218 rows=1000 loops=1)
               Buckets: 1024  Batches: 1  Memory Usage: 44kB
               ->  Seq Scan on tb3  (cost=0.00..15.00 rows=1000 width=4) (actual time=0.009..0.088 rows=1000 loops=1)
 Planning Time: 0.109 ms
 Execution Time: 128.466 ms
(14 rows)
```



出现上面的问题的原因在优化器于tb1和tb2 JOIN后的结果集大小估算出现了严重的偏差，估算值是1行，但实际是10w行。



**为什么出现这么大的偏差？**

先看下PG如何估算JOIN的结果集行数。

对于2表JOIN的结果集行数估算，可以大致简化为如下的公式：

```
2表的笛卡尔积 * Join条件1的选择率 * Join条件2的选择率 * ...
```

JOIN条件的选择率和JOIN字段的数据分布有关，对于不能适用频繁值和柱状图的场景（本例），选择率为2个表的唯一值较大的那个值的倒数。具体参考`eqjoinsel_inner()`中的代码：

```
		double		nullfrac1 = stats1 ? stats1->stanullfrac : 0.0;
		double		nullfrac2 = stats2 ? stats2->stanullfrac : 0.0;

		selec = (1.0 - nullfrac1) * (1.0 - nullfrac2);
		if (nd1 > nd2)
			selec /= nd1;
		else
			selec /= nd2;
```

上述估算假设每个Join条件对结果集的过滤效果都是独立的，但实际上它们可能是相关的（比如本例），这就导致有多个JOIN条件时，特别容易出现大的偏差。

对于单表的多个具有相关性的条件组合的部分场景，我们可以通过创建扩展统计的方式优化；但对于这种涉及多表的多个JOIN条件组合场景，目前没有好的办法能让优化器获得更加准确的行估算。



## 4. 解决方案

只能通过改写SQL的方式回避（或者`pg_hint_plan`插件）,比如把Join条件改成如下的等价形式影响行估算，进而改变执行计划。

```
tb1.c2=tb2.c2
==>
tb1.c2+0=tb2.c2+0
```

改写后的SQL：

```
select count(*) from tb1,tb2,tb3
  where tb1.c1=tb2.c1 and tb1.c2+0=tb2.c2+0
        and tb1.d=tb3.d
```

改写后的执行计划：

```
postgres=# explain analyze
postgres-# select count(*) from tb1,tb2,tb3
postgres-#   where tb1.c1=tb2.c1 and tb1.c2+0=tb2.c2+0
postgres-#         and tb1.d=tb3.d;
                                                            QUERY PLAN
-----------------------------------------------------------------------------------------------------------------------------------
 Aggregate  (cost=7284.62..7284.64 rows=1 width=8) (actual time=158.687..158.690 rows=1 loops=1)
   ->  Hash Join  (cost=3361.50..7283.38 rows=500 width=0) (actual time=43.258..151.051 rows=99901 loops=1)
         Hash Cond: (tb1.d = tb3.d)
         ->  Hash Join  (cost=3334.00..7249.00 rows=500 width=4) (actual time=42.365..127.613 rows=100000 loops=1)
               Hash Cond: ((tb1.c1 = tb2.c1) AND ((tb1.c2 + 0) = (tb2.c2 + 0)))
               ->  Seq Scan on tb1  (cost=0.00..1541.00 rows=100000 width=12) (actual time=0.022..12.525 rows=100000 loops=1)
               ->  Hash  (cost=1443.00..1443.00 rows=100000 width=8) (actual time=41.936..41.937 rows=100000 loops=1)
                     Buckets: 131072  Batches: 2  Memory Usage: 2982kB
                     ->  Seq Scan on tb2  (cost=0.00..1443.00 rows=100000 width=8) (actual time=0.046..11.682 rows=100000 loops=1)
         ->  Hash  (cost=15.00..15.00 rows=1000 width=4) (actual time=0.538..0.538 rows=1000 loops=1)
               Buckets: 1024  Batches: 1  Memory Usage: 44kB
               ->  Seq Scan on tb3  (cost=0.00..15.00 rows=1000 width=4) (actual time=0.047..0.248 rows=1000 loops=1)
 Planning Time: 0.306 ms
 Execution Time: 159.037 ms
(14 rows)
```

虽然上面SQL改写后的行估算偏差仍然很大，但已经成功改变了执行计划，执行时间只有159ms。



## 5. 参考

- http://www.interdb.jp/pg/pgsql03.html
