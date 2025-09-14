
优化SQL时，一般都需要分析执行计划，下面介绍几种获取PostgreSQL执行计划的方法。
## 测试数据准备
```
create table tb1(id int primary key,c1 int);
insert into tb1 select id,id%10 from generate_series(1,100)id;
analyze tb1;
```

## 方法1：执行explain + SQL
```
postgres=# explain select * from tb1 where id=1;
                             QUERY PLAN
--------------------------------------------------------------------
 Index Scan using tb1_pkey on tb1  (cost=0.15..8.17 rows=1 width=8)
   Index Cond: (id = 1)
(2 rows)
```
通过执行计划可以看到数据库在执行SQL时采用的表扫描方式，join方式等关键信息
- 执行计划的解读参考：http://www.postgres.cn/docs/12/using-explain.html
- PG的优化器选择执行计划时基于代价估算，代价估算的详细算法可参考：http://www.interdb.jp/pg/pgsql03.html

## 方法2：执行explain (analyze,buffers) + SQL

```
postgres=# explain (analyze,buffers) select * from tb1 where id=1;
                                         QUERY PLAN
---------------------------------------------------------------------------------------------
 Seq Scan on tb1  (cost=0.00..2.25 rows=1 width=8) (actual time=0.016..0.051 rows=1 loops=1)
   Filter: (id = 1)
   Rows Removed by Filter: 99
   Buffers: shared hit=1
 Planning:
   Buffers: shared hit=18
 Planning Time: 0.221 ms
 Execution Time: 0.070 ms
(8 rows)
```
使用`explain (analyze,buffers)`会实际执行SQL，从输出结果中可以获取一些重要信息。
- SQL执行时间具体消耗在哪里
- 优化器估算的行数和实际的行数是否有大的偏差
- 逻辑读和物理读的数量

优化器估算的行数和实际偏差过大容易造成执行计划走偏。而估算的行数偏差大的原因有很多种，比如统计信息不准，多个条件组合，对条件字段使用表达式等等，需要具体分析。

注意，不要轻易使用这种方式执行DML语句，会实际修改数据。可以改写成select，或者把SQL包在事务里，执行完DMl后回滚事务。

## 方法3：使用预编译方式执行SQL
有时候应用程序里跑的SQL很慢，但把SQL提出来单独跑却很快。出现这种现象，首先要排查几点。
- 两边代入的常量和参数值是否完全一样
- 应用代码里是否使用了不匹配的类型映射。
  比如mybatis中定义SQL参数时指定的JavaType是否和数据库的字段类型一致，以及传递实参时使用的Java对象的类型是否和数据库的字段类型一致。
- 数据，统计信息是否发生过变化
- 参数配置是否有差异

如果以上原因都排除，那还有一种常见的原因，可能是应用程序里使用预编译方式执行并采用了通用执行计划，而单独跑SQL没有使用预编译方式执行。

对预编译语句有2种方式生成执行计划，这2种方式生成的执行计划可能不一样。
- 定制执行计划：根据实际代入的参数值，生成执行计划。通常可以获得更好的执行计划，但是每次执行SQL都是硬解析。
- 通用执行计划：忽视代入的参数值，生成通用的执行计划。有时这种执行计划不是最优，但是可以复用执行计划，避免SQL硬解析。

默认情况下（`plan_cache_mode=auto`），预编译语句前5次执行时，采用定制执行计划。
如果通用执行计划的cost小于前5次定制执行计划的平均cost+plan的代价，那么以后执行时都会采用通用执行计划。
另外，由于JDBC驱动中，对同一个预编译语句,执行5次以上才会生成有特定名字的预编译语句。
因此，有时可能会发现JAVA应用中，某条SQL前10次执行很快，第11次以后SQL突然变慢。这就是因为执行计划发生了切换。

相关代码参考附录1：`choose_custom_plan()`函数

可以通过以下方式，使用预编译方式单独执行SQL，并采用通用执行计划。
```
prepare p1 as select * from tb1 where id=$1;

set plan_cache_mode=force_generic_plan;
explain (analyze,buffers) execute p1(1);
```

上面的p1是预编译语句名，预编译语句是会话级的，只对本会话可见，会话结束时自动释放。也可以通用以下SQL显式释放。
```
deallocate p1;
```

## 方法4：通过`auto_explain`插件获取慢SQL的执行计划

安装`auto_explain`插件，可以自动输出执行时长超过指定阈值的SQL的执行计划到日志文件。

配置示例如下：
```
# postgresql.conf
session_preload_libraries = 'auto_explain'

auto_explain.log_min_duration = '3s'
```

参考：http://www.postgres.cn/docs/12/auto-explain.html


## 方法4：通过第3方插件`pg_show_plans`获取运行中的SQL的执行计划

使用方法参考相关手册。
- https://github.com/cybertec-postgresql/pg_show_plans

获取运行中的SQL的执行计划是一个非常实用的特性，可惜pg原生没有提供这一功能，对于侵入性强的第3方插件，生产使用需要严格评估。


## 附录1：choose_custom_plan()函数
```
/*
 * choose_custom_plan: choose whether to use custom or generic plan
 *
 * This defines the policy followed by GetCachedPlan.
 */
static bool
choose_custom_plan(CachedPlanSource *plansource, ParamListInfo boundParams)
{
    ...
 	/* Let settings force the decision */
	if (plan_cache_mode == PLAN_CACHE_MODE_FORCE_GENERIC_PLAN)
		return false;
	if (plan_cache_mode == PLAN_CACHE_MODE_FORCE_CUSTOM_PLAN)
		return true;
    ...
	/* Generate custom plans until we have done at least 5 (arbitrary) */
	if (plansource->num_custom_plans < 5)
		return true;

	avg_custom_cost = plansource->total_custom_cost / plansource->num_custom_plans;

	...
	/*
	 * Prefer generic plan if it's less expensive than the average custom
	 * plan.  (Because we include a charge for cost of planning in the
	 * custom-plan costs, this means the generic plan only has to be less
	 * expensive than the execution cost plus replan cost of the custom
	 * plans.)
	 *
	 * Note that if generic_cost is -1 (indicating we've not yet determined
	 * the generic plan cost), we'll always prefer generic at this point.
	 */
	if (plansource->generic_cost < avg_custom_cost)
		return false;

	return true;
}
```


## 附录2：通用执行计划导致慢SQL
下面通过一个例子演示，通用执行计划导致慢SQL的场景。

测试数据准备
```
create table tb1(id int primary key,c1 int);
insert into tb1 select id,id%10 from generate_series(1,10000)id;
create index on tb1(c1);
analyze tb1;
```

这个例子中，代入不同参数值，最优的执行计划是不一样的。

代入参数值1，匹配记录多，采用bitmap index扫描。
```
postgres=# explain select * from tb1 where c1=1;;
                                 QUERY PLAN
-----------------------------------------------------------------------------
 Bitmap Heap Scan on tb1  (cost=16.04..73.53 rows=1000 width=8)
   Recheck Cond: (c1 = 1)
   ->  Bitmap Index Scan on tb1_c1_idx  (cost=0.00..15.79 rows=1000 width=0)
         Index Cond: (c1 = 1)
(4 rows)
```

代入参数值-1，没有匹配记录，采用index扫描。
```
postgres=# explain select * from tb1 where c1=-1;;
                              QUERY PLAN
----------------------------------------------------------------------
 Index Scan using tb1_c1_idx on tb1  (cost=0.29..8.26 rows=1 width=8)
   Index Cond: (c1 = '-1'::integer)
(2 rows)
```

以预编译方式执行，并且代入参数值1，连续执行6次，执行计划已经切换成了通用执行计划（参数值1被替换成$1）。
参数值1的定制执行计划和通用执行计划是相同的，但是使用通用执行计划减少了plan的cost，因此在第6次执行时，通用执行计划占优。
```
postgres=# prepare p1 as select * from tb1 where c1=$1;
PREPARE
postgres=# explain execute p1(1);
                                 QUERY PLAN
-----------------------------------------------------------------------------
 Bitmap Heap Scan on tb1  (cost=16.04..73.53 rows=1000 width=8)
   Recheck Cond: (c1 = 1)
   ->  Bitmap Index Scan on tb1_c1_idx  (cost=0.00..15.79 rows=1000 width=0)
         Index Cond: (c1 = 1)
(4 rows)

postgres=# explain execute p1(1);
                                 QUERY PLAN
-----------------------------------------------------------------------------
 Bitmap Heap Scan on tb1  (cost=16.04..73.53 rows=1000 width=8)
   Recheck Cond: (c1 = 1)
   ->  Bitmap Index Scan on tb1_c1_idx  (cost=0.00..15.79 rows=1000 width=0)
         Index Cond: (c1 = 1)
(4 rows)

postgres=# explain execute p1(1);
                                 QUERY PLAN
-----------------------------------------------------------------------------
 Bitmap Heap Scan on tb1  (cost=16.04..73.53 rows=1000 width=8)
   Recheck Cond: (c1 = 1)
   ->  Bitmap Index Scan on tb1_c1_idx  (cost=0.00..15.79 rows=1000 width=0)
         Index Cond: (c1 = 1)
(4 rows)

postgres=# explain execute p1(1);
                                 QUERY PLAN
-----------------------------------------------------------------------------
 Bitmap Heap Scan on tb1  (cost=16.04..73.53 rows=1000 width=8)
   Recheck Cond: (c1 = 1)
   ->  Bitmap Index Scan on tb1_c1_idx  (cost=0.00..15.79 rows=1000 width=0)
         Index Cond: (c1 = 1)
(4 rows)

postgres=# explain execute p1(1);
                                 QUERY PLAN
-----------------------------------------------------------------------------
 Bitmap Heap Scan on tb1  (cost=16.04..73.53 rows=1000 width=8)
   Recheck Cond: (c1 = 1)
   ->  Bitmap Index Scan on tb1_c1_idx  (cost=0.00..15.79 rows=1000 width=0)
         Index Cond: (c1 = 1)
(4 rows)

postgres=# explain execute p1(1);
                                 QUERY PLAN
-----------------------------------------------------------------------------
 Bitmap Heap Scan on tb1  (cost=16.04..73.53 rows=1000 width=8)
   Recheck Cond: (c1 = $1)
   ->  Bitmap Index Scan on tb1_c1_idx  (cost=0.00..15.79 rows=1000 width=0)
         Index Cond: (c1 = $1)
(4 rows)
```

此时，代入参数值-1，也会采用bitmap index扫描。
```
postgres=# explain execute p1(-1);
                                 QUERY PLAN
-----------------------------------------------------------------------------
 Bitmap Heap Scan on tb1  (cost=16.04..73.53 rows=1000 width=8)
   Recheck Cond: (c1 = $1)
   ->  Bitmap Index Scan on tb1_c1_idx  (cost=0.00..15.79 rows=1000 width=0)
         Index Cond: (c1 = $1)
(4 rows)
```

前N次执行过程中，如果代入过参数值-1，定制执行计划的平均cost被拉低，那么后面还是继续使用定制执行计划,直到随着执行次数的积累，定制执行计划的平均cost高于通用执行计划。
```
postgres=# prepare p1 as select * from tb1 where c1=$1;
PREPARE
postgres=# explain execute p1(-1);
                              QUERY PLAN
----------------------------------------------------------------------
 Index Scan using tb1_c1_idx on tb1  (cost=0.29..8.26 rows=1 width=8)
   Index Cond: (c1 = '-1'::integer)
(2 rows)

postgres=# explain execute p1(1);
                                 QUERY PLAN
-----------------------------------------------------------------------------
 Bitmap Heap Scan on tb1  (cost=16.04..73.53 rows=1000 width=8)
   Recheck Cond: (c1 = 1)
   ->  Bitmap Index Scan on tb1_c1_idx  (cost=0.00..15.79 rows=1000 width=0)
         Index Cond: (c1 = 1)
(4 rows)

...（重复12次）

postgres=# explain execute p1(1);
                                 QUERY PLAN
-----------------------------------------------------------------------------
 Bitmap Heap Scan on tb1  (cost=16.04..73.53 rows=1000 width=8)
   Recheck Cond: (c1 = $1)
   ->  Bitmap Index Scan on tb1_c1_idx  (cost=0.00..15.79 rows=1000 width=0)
         Index Cond: (c1 = $1)
(4 rows)

postgres=# explain execute p1(-1);
                                 QUERY PLAN
-----------------------------------------------------------------------------
 Bitmap Heap Scan on tb1  (cost=16.04..73.53 rows=1000 width=8)
   Recheck Cond: (c1 = $1)
   ->  Bitmap Index Scan on tb1_c1_idx  (cost=0.00..15.79 rows=1000 width=0)
         Index Cond: (c1 = $1)
(4 rows)
```

