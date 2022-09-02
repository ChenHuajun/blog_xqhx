## 1. 问题
最近遇到一个案例，PostgreSQL执行一条SQL时，在JOIN的内表扫描时，不走cost低得多的索引扫描而选择了cost更高的全表扫描，导致SQL执行很慢。
以下是模拟这个问题的示例

## 2. 示例

### 2.1 建表SQL
```
create table tb1(c1 int,c2 int);
insert into tb1 select id,id from generate_series(1,100000)id;

create table tb2(c1 int,c2 int);
insert into tb2 select id,id from generate_series(1,1000)id;
create index on tb2(c1);
```

### 2.2 问题SQL
```
postgres=# explain analyze
select 1 from tb1 join tb2 on(tb1.c1=tb2.c1)
where tb1.c2<1000 and tb1.c2=tb1.c2+0 and tb1.c2=tb1.c2-0;
                                                 QUERY PLAN
------------------------------------------------------------------------------------------------------------
 Nested Loop  (cost=0.00..2970.50 rows=1 width=4) (actual time=0.031..250.735 rows=999 loops=1)
   Join Filter: (tb1.c1 = tb2.c1)
   Rows Removed by Join Filter: 998001
   ->  Seq Scan on tb1  (cost=0.00..2943.00 rows=1 width=4) (actual time=0.019..12.146 rows=999 loops=1)
         Filter: ((c2 < 1000) AND (c2 = (c2 + 0)) AND ((c2 + 0) = (c2 - 0)))
         Rows Removed by Filter: 99001
   ->  Seq Scan on tb2  (cost=0.00..15.00 rows=1000 width=4) (actual time=0.007..0.116 rows=1000 loops=999)
 Planning Time: 0.149 ms
 Execution Time: 250.877 ms
(9 rows)
```

以上，对tb2执行了全表扫描。


### 2.3 禁止全表扫描后的执行计划对比
```
postgres=# set enable_seqscan=off;
SET
postgres=# explain analyze
select 1 from tb1 join tb2 on(tb1.c1=tb2.c1)
where tb1.c2<1000 and tb1.c2=tb1.c2+0 and tb1.c2=tb1.c2-0;
                                                         QUERY PLAN
-----------------------------------------------------------------------------------------------------------------------------
 Nested Loop  (cost=10000000000.27..10000002951.30 rows=1 width=4) (actual time=0.025..20.658 rows=999 loops=1)
   ->  Seq Scan on tb1  (cost=10000000000.00..10000002943.00 rows=1 width=4) (actual time=0.013..17.628 rows=999 loops=1)
         Filter: ((c2 < 1000) AND (c2 = (c2 + 0)) AND ((c2 + 0) = (c2 - 0)))
         Rows Removed by Filter: 99001
   ->  Index Only Scan using tb2_c1_idx on tb2  (cost=0.28..8.29 rows=1 width=4) (actual time=0.002..0.003 rows=1 loops=999)
         Index Cond: (c1 = tb1.c1)
         Heap Fetches: 999
 Planning Time: 0.264 ms
 Execution Time: 20.763 ms
(9 rows)
```

禁止全表扫描后，对tb2执行了索引扫描。

## 3. 原因

对比2个执行计划，索引扫描的total cost(0.28..8.29)明显低于全表扫描（0.00..15.00），优化器为什么没有选择索引扫描？
查询相关代码，判断原因如下
1. 内表的扫描不是一个独立的path，而只是上层Nested Loop的一部分，对比不同path的cost时，比较的是上层的Nested Loop。
2. Nested Loop的2个不同path的cost分别是索引扫描的(0.27..2951.30)和全表扫描的(0.00..2970.50)
3. 比较2个path代价时，先比较total cost，由于2个path的total cost的差异小于1%，认为total cost相同，继续比较start-up cost。
4. 全表扫描的start-up cost低于索引扫描的0.27，因此全表扫描胜出。

示例的SQL执行慢，还由于Join外表的行估算偏差过大。实际999行，估算值只有1行，导致全表扫描的代价没有在Nested Loop Join的cost里得到充分体现。
要解决这个问题，可以添加索引或者添加冗余条件干预优化器的代价估算。

## 4. 附录：相关代码

```
src/backend/optimizer/util/pathnode.c
```
/*
 * STD_FUZZ_FACTOR is the normal fuzz factor for compare_path_costs_fuzzily.
 * XXX is it worth making this user-controllable?  It provides a tradeoff
 * between planner runtime and the accuracy of path cost comparisons.
 */
#define STD_FUZZ_FACTOR 1.01
...
static PathCostComparison
compare_path_costs_fuzzily(Path *path1, Path *path2, double fuzz_factor)
{
#define CONSIDER_PATH_STARTUP_COST(p)  \
	((p)->param_info == NULL ? (p)->parent->consider_startup : (p)->parent->consider_param_startup)

	/*
	 * Check total cost first since it's more likely to be different; many
	 * paths have zero startup cost.
	 */
	if (path1->total_cost > path2->total_cost * fuzz_factor)
	{
		/* path1 fuzzily worse on total cost */
		if (CONSIDER_PATH_STARTUP_COST(path1) &&
			path2->startup_cost > path1->startup_cost * fuzz_factor)
		{
			/* ... but path2 fuzzily worse on startup, so DIFFERENT */
			return COSTS_DIFFERENT;
		}
		/* else path2 dominates */
		return COSTS_BETTER2;
	}
	if (path2->total_cost > path1->total_cost * fuzz_factor)
	{
		/* path2 fuzzily worse on total cost */
		if (CONSIDER_PATH_STARTUP_COST(path2) &&
			path1->startup_cost > path2->startup_cost * fuzz_factor)
		{
			/* ... but path1 fuzzily worse on startup, so DIFFERENT */
			return COSTS_DIFFERENT;
		}
		/* else path1 dominates */
		return COSTS_BETTER1;
	}
	/* fuzzily the same on total cost ... */
	if (path1->startup_cost > path2->startup_cost * fuzz_factor)
	{
		/* ... but path1 fuzzily worse on startup, so path2 wins */
		return COSTS_BETTER2;
	}
	if (path2->startup_cost > path1->startup_cost * fuzz_factor)
	{
		/* ... but path2 fuzzily worse on startup, so path1 wins */
		return COSTS_BETTER1;
	}
	/* fuzzily the same on both costs */
	return COSTS_EQUAL;

#undef CONSIDER_PATH_STARTUP_COST
}
```





