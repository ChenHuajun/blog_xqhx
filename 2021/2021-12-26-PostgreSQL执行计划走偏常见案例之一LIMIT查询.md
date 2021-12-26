# PostgreSQL执行计划走偏常见案例之一LIMIT查询



## 1. 前言

PostgreSQL的优化器基于代价选择最优的执行计划，也就是所谓的CBO（Cost-Based Optimization）。借助PostgreSQL后台针对表数据分布收集的丰富的统计信息，CBO大多数时候运作得很好。但是，CBO不能解决所有问题，有些场景下很容易出现估算偏差，从而选用糟糕的执行计划。这里举几个常见的例子，这些例子都是我们生产环境中多次遇到过的。

第一个例子，可能也是大家最容易遇到的一个例子，就是带LIMIT的查询，比如分页查询。



## 2. 示例

数据准备：

```
create table tb1(id int primary key,c1 int);
create index on tb1(c1);

insert into tb1 select id, id/10000 from generate_series(1,10000000)id;
```



查询SQL：

```
select * from tb1 where c1=999 order by id limit 10
```



执行计划

```
postgres=# explain analyze select * from tb1 where c1=999 order by id limit 10;
                                                            QUERY PLAN
-----------------------------------------------------------------------------------------------------------------------------------
 Limit  (cost=0.43..332.29 rows=10 width=8) (actual time=1571.315..1571.319 rows=10 loops=1)
   ->  Index Scan using tb1_pkey on tb1  (cost=0.43..328935.03 rows=9912 width=8) (actual time=1571.314..1571.316 rows=10 loops=1)
         Filter: (c1 = 999)
         Rows Removed by Filter: 9989999
 Planning Time: 0.112 ms
 Execution Time: 1571.337 ms
(6 rows)
```

这个执行计划是非常低效的，表里总共有1000w记录，但是这个执行计划却通过索引扫描读取了999w无效的元组，然后又不得不丢弃（ `Rows Removed by Filter: 9989999`）。反映到SQL执行时间上是1571ms。



## 3. 分析

从经验上看下，先通过c1字段上索引找到所有`c1=999`的元组再排序应该会更优。那么PG为什么会选择使用id字段上的主键索引呢？

既然PG是CBO的优化器，那么原因必然是PG估算后认为这个被选中的执行计划的代价更低。如果执行计划选的不合理，必然是代价估算出了问题。

使用id字段上的主键索引可以省掉排序步骤，但是却无法快速定位到`c1=999`的元组，只能暴力过滤，因此PG对`Index Scan` 给出了328935的高代价。但是由于SQL中有`limit 10`，并且PG假设匹配`c1=999`的9912条记录分布是均匀的，所以给出的最终估算只有332（近似等于`328935 * 10 / 9912`）。

但是，实际上，这个例子中数据分布不是均匀的。c1和id的分布有很大的相关性，满足条件`c1=999`的元组都集中在id范围的末尾，走id索引需要遍历到索引尾部才能找到10条记录。

PG显然对LIMIT子句使用了非常理想化的估算模型，真实场景下很容易出现大的偏差（即使不像本文这个精心设计的例子中这么离谱，很多时候也足以也影响到执行计划的选择）。



## 4. 解决方案

这个例子中，统计信息和行估算都没有问题，问题出在数据分布的相关性上。PG目前没办法感知这种数据分布并反映到LIMIT子句的代价估算中。所以我们只能通过改写SQL的方式回避（或者`pg_hint_plan`插件）。

**SQL改写1**

比如，把`order by id`改成`order by id+0` 避免走id索引

```
select * from tb1 where c1=999 order by id+0 limit 10
```

修改后的执行计划如下：

```
postgres=# explain analyze select * from tb1 where c1=999 order by id+0 limit 10;
                                                              QUERY PLAN
--------------------------------------------------------------------------------------------------------------------------------------
 Limit  (cost=563.08..563.10 rows=10 width=12) (actual time=4.336..4.338 rows=10 loops=1)
   ->  Sort  (cost=563.08..587.81 rows=9893 width=12) (actual time=4.335..4.336 rows=10 loops=1)
         Sort Key: ((id + 0))
         Sort Method: top-N heapsort  Memory: 25kB
         ->  Index Scan using tb1_c1_idx on tb1  (cost=0.43..349.30 rows=9893 width=12) (actual time=0.150..2.990 rows=10000 loops=1)
               Index Cond: (c1 = 999)
 Planning Time: 0.206 ms
 Execution Time: 4.375 ms
(8 rows)
```

执行时间，从1571ms缩短到4ms。



**SQL改写2**

另外，我们还可以通过把SQL改写成`WITH ... AS MATERIALIZED`的形式干预执行计划。这也是比较常用的一种手段，并且SQL的可读性比前面的`order by id+0`更好。

```
WITH t AS MATERIALIZED(
  select * from tb1 where c1=999
)
select * from t order by id limit 10
```

对于的执行计划如下

```
postgres=# explain analyze WITH t AS MATERIALIZED(
  select * from tb1 where c1=999
)
select * from t order by id limit 10;
                                                           QUERY PLAN
---------------------------------------------------------------------------------------------------------------------------------
 Limit  (cost=736.21..736.23 rows=10 width=8) (actual time=4.303..4.305 rows=10 loops=1)
   CTE t
     ->  Index Scan using tb1_c1_idx on tb1  (cost=0.43..324.56 rows=9893 width=8) (actual time=0.023..1.308 rows=10000 loops=1)
           Index Cond: (c1 = 999)
   ->  Sort  (cost=411.64..436.38 rows=9893 width=8) (actual time=4.302..4.302 rows=10 loops=1)
         Sort Key: t.id
         Sort Method: top-N heapsort  Memory: 25kB
         ->  CTE Scan on t  (cost=0.00..197.86 rows=9893 width=8) (actual time=0.024..3.104 rows=10000 loops=1)
 Planning Time: 0.090 ms
 Execution Time: 4.418 ms
(10 rows)
```

