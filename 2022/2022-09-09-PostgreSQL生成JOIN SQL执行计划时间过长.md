## 问题
有业务PostgreSQL数据库发现，一条join SQL的执行计划生成时间特别长，接近1秒。
后定位出原因是`default_statistics_target`设置过大导致。
下面用一个例子演示一下。



## 示例

连接到数据库，建表并插入数据
```
create table tb1(id int);
create table tb2(id int);
insert into tb1 select generate_series(1,1000000);
insert into tb2 select generate_series(1,1000000);
insert into tb1 select (random()*10000) :: int  from generate_series(1,100000);
insert into tb2 select (random()*10000) :: int  from generate_series(1,100000);
```

设置`default_statistics_target`为非常大的值10000并收集统计信息
```
set default_statistics_target to 10000;
analyze tb1,tb2;
```

生成执行计划,执行计划生成非常耗时。
```
postgres=# select array_length(most_common_vals,1) from pg_stats where tablename='tb1';
 array_length
--------------
        10000
(1 row)
postgres=# \timing
Timing is on.
postgres=# explain select 1 from tb1 a join tb2 b on(a.id=b.id);
                                QUERY PLAN
---------------------------------------------------------------------------
 Hash Join  (cost=33915.00..121795.90 rows=2199690 width=4)
   Hash Cond: (a.id = b.id)
   ->  Seq Scan on tb1 a  (cost=0.00..15868.00 rows=1100000 width=4)
   ->  Hash  (cost=15868.00..15868.00 rows=1100000 width=4)
         ->  Seq Scan on tb2 b  (cost=0.00..15868.00 rows=1100000 width=4)
(5 rows)

Time: 401.352 ms
```

尝试不同`default_statistics_target`值，explain的执行时间分别如下
```
10000(10000,10000): 401.352 ms
5000(5000,5000)   : 171.344 ms
2000(2000,2000)   : 32.697 ms
1000(1000,1000)   : 11.059 ms
500(183,182)      : 1.349 ms
100(null,null)    : 0.950 ms
```
括号里为tb1和tb2实际`most_common_vals`数组的长度，即`default_statistics_target=500`时，tb1和tb2的实际mcv数组大小分别是183和182。

## 原因
采集explain的堆栈如下(PG 12)：
```
#0  0x00000000008f8efe in int4eq (fcinfo=0x7ffc3c6be280) at int.c:382
#1  0x00000000009ef3e7 in FunctionCall2Coll (flinfo=0x7ffc3c6be320, collation=0, arg1=7660, arg2=4916) at fmgr.c:1162
#2  0x0000000000982945 in eqjoinsel_inner (opfuncoid=65, collation=0, vardata1=0x7ffc3c6be510, vardata2=0x7ffc3c6be4e0, nd1=1000001, nd2=1000001, isdefault1=false, isdefault2=false, sslot1=0x7ffc3c6be490, sslot2=0x7ffc3c6be450, stats1=0x15ebc40, stats2=0x15ce3b0, have_mcvs1=true, have_mcvs2=true) at selfuncs.c:2262
#3  0x00000000009824ae in eqjoinsel (fcinfo=0x7ffc3c6be610) at selfuncs.c:2113
#4  0x00000000009ef75e in FunctionCall5Coll (flinfo=0x7ffc3c6be6d0, collation=0, arg1=22980880, arg2=96, arg3=22787928, arg4=0, arg5=140721322191584) at fmgr.c:1243
#5  0x00000000009eff7b in OidFunctionCall5Coll (functionId=105, collation=0, arg1=22980880, arg2=96, arg3=22787928, arg4=0, arg5=140721322191584) at fmgr.c:1461
#6  0x00000000007bac06 in join_selectivity (root=0x15ea910, operatorid=96, args=0x15bb758, inputcollid=0, jointype=JOIN_INNER, sjinfo=0x7ffc3c6beae0) at plancat.c:1828
#7  0x0000000000760cc3 in clause_selectivity (root=0x15ea910, clause=0x15bb6e8, varRelid=0, jointype=JOIN_INNER, sjinfo=0x7ffc3c6beae0) at clausesel.c:769
#8  0x000000000076008b in clauselist_selectivity_simple (root=0x15ea910, clauses=0x15bb9d8, varRelid=0, jointype=JOIN_INNER, sjinfo=0x7ffc3c6beae0, estimatedclauses=0x0) at clausesel.c:173
#9  0x000000000075ffd9 in clauselist_selectivity (root=0x15ea910, clauses=0x15bb9d8, varRelid=0, jointype=JOIN_INNER, sjinfo=0x7ffc3c6beae0) at clausesel.c:106
#10 0x00000000007681e7 in calc_joinrel_size_estimate (root=0x15ea910, joinrel=0x15bb308, outer_rel=0x15ccaf8, inner_rel=0x15ba398, outer_rows=1100000, inner_rows=1200000, sjinfo=0x7ffc3c6beae0, restrictlist_in=0x15bb9d8) at costsize.c:4643
#11 0x0000000000767f43 in set_joinrel_size_estimates (root=0x15ea910, rel=0x15bb308, outer_rel=0x15ccaf8, inner_rel=0x15ba398, sjinfo=0x7ffc3c6beae0, restrictlist=0x15bb9d8) at costsize.c:4498
#12 0x00000000007bf66a in build_join_rel (root=0x15ea910, joinrelids=0x15bb2e8, outer_rel=0x15ccaf8, inner_rel=0x15ba398, sjinfo=0x7ffc3c6beae0, restrictlist_ptr=0x7ffc3c6bead8) at relnode.c:710
#13 0x0000000000775f2e in make_join_rel (root=0x15ea910, rel1=0x15ccaf8, rel2=0x15ba398) at joinrels.c:724
#14 0x000000000077562d in make_rels_by_clause_joins (root=0x15ea910, old_rel=0x15ccaf8, other_rels=0x15bb298) at joinrels.c:289
#15 0x00000000007752ca in join_search_one_level (root=0x15ea910, level=2) at joinrels.c:111
#16 0x000000000075eda9 in standard_join_search (root=0x15ea910, levels_needed=2, initial_rels=0x15bb268) at allpaths.c:2885
#17 0x000000000075ed48 in make_rel_from_joinlist (root=0x15ea910, joinlist=0x15ba6d8) at allpaths.c:2816
#18 0x000000000075b8b6 in make_one_rel (root=0x15ea910, joinlist=0x15ba6d8) at allpaths.c:227
#19 0x000000000078a127 in query_planner (root=0x15ea910, qp_callback=0x78f5f2 <standard_qp_callback>, qp_extra=0x7ffc3c6bee20) at planmain.c:271
#20 0x000000000078ce9c in grouping_planner (root=0x15ea910, inheritance_update=false, tuple_fraction=0) at planner.c:2048
#21 0x000000000078b67a in subquery_planner (glob=0x15ea880, parse=0x15ccd08, parent_root=0x0, hasRecursion=false, tuple_fraction=0) at planner.c:1012
#22 0x000000000078a479 in standard_planner (parse=0x15ccd08, cursorOptions=256, boundParams=0x0) at planner.c:406
#23 0x000000000078a22e in planner (parse=0x15ccd08, cursorOptions=256, boundParams=0x0) at planner.c:275
#24 0x000000000087b6b9 in pg_plan_query (querytree=0x15ccd08, cursorOptions=256, boundParams=0x0) at postgres.c:878
#25 0x000000000061de44 in ExplainOneQuery (query=0x15ccd08, cursorOptions=256, into=0x0, es=0x15cca68, queryString=0x14fada0 "explain select 1 from tb1 a join tb2 b on(a.id=b.id);", params=0x0, queryEnv=0x0) at explain.c:368
#26 0x000000000061db81 in ExplainQuery (pstate=0x151abf8, stmt=0x14fbe48, queryString=0x14fada0 "explain select 1 from tb1 a join tb2 b on(a.id=b.id);", params=0x0, queryEnv=0x0, dest=0x151ab68) at explain.c:256
#27 0x00000000008836ab in standard_ProcessUtility (pstmt=0x15e2428, queryString=0x14fada0 "explain select 1 from tb1 a join tb2 b on(a.id=b.id);", context=PROCESS_UTILITY_TOPLEVEL, params=0x0, queryEnv=0x0, dest=0x151ab68, completionTag=0x7ffc3c6bf4d0 "") at utility.c:675
#28 0x0000000000882f35 in ProcessUtility (pstmt=0x15e2428, queryString=0x14fada0 "explain select 1 from tb1 a join tb2 b on(a.id=b.id);", context=PROCESS_UTILITY_TOPLEVEL, params=0x0, queryEnv=0x0, dest=0x151ab68, completionTag=0x7ffc3c6bf4d0 "") at utility.c:360
#29 0x0000000000881f55 in PortalRunUtility (portal=0x1561c30, pstmt=0x15e2428, isTopLevel=true, setHoldSnapshot=true, dest=0x151ab68, completionTag=0x7ffc3c6bf4d0 "") at pquery.c:1171
#30 0x0000000000881ce1 in FillPortalStore (portal=0x1561c30, isTopLevel=true) at pquery.c:1044
#31 0x000000000088169b in PortalRun (portal=0x1561c30, count=9223372036854775807, isTopLevel=true, run_once=true, dest=0x15e2508, altdest=0x15e2508, completionTag=0x7ffc3c6bf6b0 "") at pquery.c:774
#32 0x000000000087bc09 in exec_simple_query (query_string=0x14fada0 "explain select 1 from tb1 a join tb2 b on(a.id=b.id);") at postgres.c:1215
#33 0x000000000087fbb9 in PostgresMain (argc=1, argv=0x1520c78, dbname=0x1520bb8 "postgres", username=0x1520b98 "postgres") at postgres.c:4281
#34 0x00000000007e6bc9 in BackendRun (port=0x151ad40) at postmaster.c:4510
#35 0x00000000007e63b0 in BackendStartup (port=0x151ad40) at postmaster.c:4193
#36 0x00000000007e2a87 in ServerLoop () at postmaster.c:1725
#37 0x00000000007e2360 in PostmasterMain (argc=3, argv=0x14f5a40) at postmaster.c:1398
#38 0x000000000070f54e in main (argc=3, argv=0x14f5a40) at main.c:228
```


上面`operatorid=96`对应的操作符是整形的`=`操作符
```
postgres=# select * from pg_operator where oid=96;
 oid | oprname | oprnamespace | oprowner | oprkind | oprcanmerge | oprcanhash | oprleft | oprright | oprresult | oprcom | oprnegate | oprcode | oprrest |  oprjoin
-----+---------+--------------+----------+---------+-------------+------------+---------+----------+-----------+--------+-----------+---------+---------+-----------
  96 | =       |           11 |       10 | b       | t           | t          |      23 |       23 |        16 |     96 |       518 | int4eq  | eqsel   | eqjoinsel
(1 row)
```

查看相关代码，explain慢主要由于估算JOIN选择性的时候,有一个对MCV列表大小的复杂度为O(N1*N2)的计算。
```
static double
eqjoinsel_inner(Oid opfuncoid, Oid collation,
				VariableStatData *vardata1, VariableStatData *vardata2,
				double nd1, double nd2,
				bool isdefault1, bool isdefault2,
				AttStatsSlot *sslot1, AttStatsSlot *sslot2,
				Form_pg_statistic stats1, Form_pg_statistic stats2,
				bool have_mcvs1, bool have_mcvs2)
{
...
		/*
		 * Note we assume that each MCV will match at most one member of the
		 * other MCV list.  If the operator isn't really equality, there could
		 * be multiple matches --- but we don't look for them, both for speed
		 * and because the math wouldn't add up...
		 */
		matchprodfreq = 0.0;
		nmatches = 0;
		for (i = 0; i < sslot1->nvalues; i++)
		{
			int			j;

			for (j = 0; j < sslot2->nvalues; j++)
			{
				if (hasmatch2[j])
					continue;
				if (DatumGetBool(FunctionCall2Coll(&eqproc,
												   collation,
												   sslot1->values[i],
												   sslot2->values[j])))
				{
					hasmatch1[i] = hasmatch2[j] = true;
					matchprodfreq += sslot1->numbers[i] * sslot2->numbers[j];
					nmatches++;
					break;
				}
			}
		}
```

## 小结
1. 谨慎调节全局的统计目标(`default_statistics_target`)
2. 需要调整统计目标时优先针对具体的字段进行设置
3. 很多时候，通过调大统计目标使统计信息变的准确（唯一值数），不如直接设置`n_distinct`更加有效（`ALTER TABLE ... ALTER COLUMN ... SET (n_distinct = ...)`)

