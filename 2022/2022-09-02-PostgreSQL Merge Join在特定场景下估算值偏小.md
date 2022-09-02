## 1. 问题
最近遇到一个案例，PostgreSQL执行一条SQL时，Merge Join的性能相比Nestloop差很多，但Merge Join估算出的cost却非常低，导致优化器选中了Merge Join。
以下是近似模拟这个问题的示例

## 2. 示例

### 2.1 建表SQL
```
create table tb1(c1 int,c2 int);
insert into tb1 select id,id from generate_series(1,1000000)id;
create index on tb1(c1);

create table tb2(c1 int,c2 int);
insert into tb2 select id,id from generate_series(1,1000)id;
```

### 2.2 示例SQL
```
postgres=# set enable_nestloop =off;
SET
postgres=# explain analyze
select 1 from tb1 join tb2 on(tb1.c1=tb2.c1)
where tb2.c2=1000;
                                                               QUERY PLAN
----------------------------------------------------------------------------------------------------------------------------------------
 Merge Join  (cost=17.94..48.56 rows=1 width=4) (actual time=1.250..1.252 rows=1 loops=1)
   Merge Cond: (tb1.c1 = tb2.c1)
   ->  Index Only Scan using tb1_c1_idx on tb1  (cost=0.42..30408.42 rows=1000000 width=4) (actual time=0.028..0.656 rows=1001 loops=1)
         Heap Fetches: 1001
   ->  Sort  (cost=17.51..17.52 rows=1 width=4) (actual time=0.413..0.413 rows=1 loops=1)
         Sort Key: tb2.c1
         Sort Method: quicksort  Memory: 25kB
         ->  Seq Scan on tb2  (cost=0.00..17.50 rows=1 width=4) (actual time=0.372..0.373 rows=1 loops=1)
               Filter: (c2 = 1000)
               Rows Removed by Filter: 999
 Planning Time: 0.578 ms
 Execution Time: 1.347 ms
(12 rows)
```

从上面可以看出`Index Only Scan`的total cost是30408.42，但其父节点`Merge Join`的total cost只有48.56。

## 3 原因
出现这个现象的原因是，Merge Join执行时，只要有一个子节点没有新的元组输出，另一个子节点也会结束扫描，即提前退出。
因此父节点的cost可能会小于子节点的cost，这个类似于Limit。

示例中tb2.c1的最大值是1000，因此沿着tb1.c1的索引扫描时，最多只需要扫描1000个元组，也就是总元组的1/1000。
因此`Index Only Scan`的total cost的30408.42大约只有1/1000会被计入到Merge Join的total cost里。


具体的cost估算方法参考`initial_cost_mergejoin()`函数代码
```
void
initial_cost_mergejoin(PlannerInfo *root, JoinCostWorkspace *workspace,
					   JoinType jointype,
					   List *mergeclauses,
					   Path *outer_path, Path *inner_path,
					   List *outersortkeys, List *innersortkeys,
					   JoinPathExtraData *extra)
{
...
		cache = cached_scansel(root, firstclause, opathkey);
...
			outerstartsel = cache->leftstartsel;  // outer关系中满足 Join字段值 < inner关系join字段取值范围的最小值的元组的占比，这个范围的元组会被过滤掉,扫描这些元组的代价被计入到startup cost。
			outerendsel = cache->leftendsel;      // outer关系中满足 Join字段值 < inner关系join字段取值范围的最大值的元组的占比，这个范围以外的元组不需要扫描，因此只有这个范围内的元组的扫描代价会被计入到total cost。
			innerstartsel = cache->rightstartsel;
			innerendsel = cache->rightendsel;
...
// 将outer关系的cost加入到Merge Join
		startup_cost += outer_path->startup_cost;
		startup_cost += (outer_path->total_cost - outer_path->startup_cost)
			* outerstartsel;                     // outerstartsel范围元组的run cost累加到Merge Join的startup_cost
		run_cost += (outer_path->total_cost - outer_path->startup_cost)
			* (outerendsel - outerstartsel);     // (outerendsel - outerstartsel)范围元组的run cost计入Merge Join的run_cost
...
// 将inner关系的cost加入到Merge Join（和outer类似）
		startup_cost += inner_path->startup_cost;
		startup_cost += (inner_path->total_cost - inner_path->startup_cost)
			* innerstartsel;
		inner_run_cost = (inner_path->total_cost - inner_path->startup_cost)
			* (innerendsel - innerstartsel);
```

PG这样估算Merge Join的cost，通常情况下和实际SQL执行时间相吻合。
但是，Merge Join会缩小子节点cost的特性，在特定场景下可能会放大估算偏差的影响，增加了选中一个性能糟糕的执行计划的概率。


