# PostgreSQL求解最短路径

有些业务中需要求解最短路径，PostgreSQL中有个pgrouting插件内置了和计算最短路径相关的算法。
下面看下示例

## 表定义

```
postgres=# \d testpath
              Table "public.testpath"
 Column |  Type   | Collation | Nullable | Default 
--------+---------+-----------+----------+---------
 id     | integer |           |          | 
 source | integer |           |          | 
 target | integer |           |          | 
 cost   | integer |           |          | 
```

这是张业务表，每一行代表一条边及其代价，总共1000多条记录（实际对应的是按业务条件筛选后的结果集大小）。其余业务相关的属性全部隐去。

## 求解2点间的最短路径

```
postgres=# SELECT * FROM pgr_dijkstra(
  'SELECT id,source,target,cost FROM testpath',
  10524, 10379, directed:=true);
 seq | path_seq | node  |  edge   | cost | agg_cost 
-----+----------+-------+---------+------+----------
   1 |        1 | 10524 | 1971852 |    1 |        0
   2 |        2 |  7952 |   32256 |    1 |        1
   3 |        3 |  7622 |   76615 |    2 |        2
   4 |        4 | 44964 |   76616 |    1 |        4
   5 |        5 |  7861 |   19582 |    1 |        5
   6 |        6 |  7629 |   14948 |    2 |        6
   7 |        7 | 17135 |   14949 |    1 |        8
   8 |        8 | 10379 |      -1 |    0 |        9
(8 rows)

Time: 22.979 ms
```

## 求解2点间最短的N条路径

```
postgres=# SELECT * FROM pgr_ksp(
  'SELECT id,source,target,cost FROM testpath',
  10524, 10379, 1000,directed:=true);
 seq | path_id | path_seq | node  |  edge   | cost | agg_cost 
-----+---------+----------+-------+---------+------+----------
   1 |       1 |        1 | 10524 | 1971852 |    1 |        0
   2 |       1 |        2 |  7952 |   32256 |    1 |        1
   3 |       1 |        3 |  7622 |   54740 |    2 |        2
   4 |       1 |        4 | 35389 |   54741 |    1 |        4
   5 |       1 |        5 |  7861 |   19582 |    1 |        5
   6 |       1 |        6 |  7629 |   14948 |    2 |        6
   7 |       1 |        7 | 17135 |   14949 |    1 |        8
   8 |       1 |        8 | 10379 |      -1 |    0 |        9
...(略)
 100 |      12 |        4 | 53179 |   95137 |    1 |        4
 101 |      12 |        5 |  7625 |   90682 |    2 |        5
 102 |      12 |        6 | 51211 |   90683 |    1 |        7
 103 |      12 |        7 |  7861 |   19582 |    1 |        8
 104 |      12 |        8 |  7629 | 1173911 |    2 |        9
 105 |      12 |        9 | 59579 | 1173917 |    1 |       11
 106 |      12 |       10 | 10379 |      -1 |    0 |       12
(106 rows)

Time: 201.223 ms
```

## 纯SQL求解最短路径

前面的最短路径是通过pgrouting插件计算的，能不能单纯利用PG自身的SQL完成最短路径的计算呢？

真实的业务场景下是可以限制路径的长度的，比如，如果我们舍弃所有边数大于7的路径。
那么完全可以用简单的深度遍历计算最短路径。计算速度还提高了5倍。

```
postgres=# WITH RECURSIVE line AS(
SELECT source,target,cost from testpath
),
path(fullpath,pathseq,node,total_cost) AS (
    select ARRAY[10524],1,10524,0
  UNION ALL
    select array_append(fullpath,target),pathseq+1,target,total_cost+cost from path join line on(source=node) where node!=10379 and pathseq<=8
)
SELECT * FROM path where fullpath @> ARRAY[10379] order by total_cost limit 1;
                   fullpath                    | pathseq | node  | total_cost 
-----------------------------------------------+---------+-------+------------
 {10524,7952,7622,80465,7861,7629,17135,10379} |       8 | 10379 |          9
(1 row)

Time: 4.334 ms
```

如果每条边的cost相同，可以去掉上面的`order by total_cost`，在大数据集上性能会有很大的提升。

## 纯SQL求解最短的N条路径

沿用前面的SQL，只是修改了一下`limit`值，相比pgrouting的`pgr_ksp`函数性能提升的更多。性能提升了50倍。

```
postgres=# WITH RECURSIVE line AS(
SELECT source,target,cost from testpath
),
path(fullpath,pathseq,node,total_cost) AS (
    select ARRAY[10524],1,10524,0
  UNION ALL
    select array_append(fullpath,target),pathseq+1,target,total_cost+cost from path join line on(source=node) where node!=10379 and pathseq<=8
)
SELECT * FROM path where fullpath @> ARRAY[10379] order by total_cost limit 1000;
                      fullpath                      | pathseq | node  | total_cost 
----------------------------------------------------+---------+-------+------------
 {10524,7952,7622,80465,7861,7629,17135,10379}      |       8 | 10379 |          9
 {10524,7952,7622,35389,7861,7629,17135,10379}      |       8 | 10379 |          9
 {10524,7952,7622,44964,7861,7629,17135,10379}      |       8 | 10379 |          9
 {10524,7952,7622,80465,7861,7629,59579,10379}      |       8 | 10379 |          9
 {10524,7952,7622,35389,7861,7629,59579,10379}      |       8 | 10379 |          9
 {10524,7952,7622,44964,7861,7629,59579,10379}      |       8 | 10379 |          9
 {10524,7952,7622,53179,7625,7861,7629,17135,10379} |       9 | 10379 |         10
 {10524,7952,7622,53179,7625,7861,7629,59579,10379} |       9 | 10379 |         10
(8 rows)

Time: 4.425 ms
```


下面看下执行计划

```
postgres=# explain analyze
WITH RECURSIVE line AS(
SELECT source,target,cost from testpath
),
path(fullpath,pathseq,node,total_cost) AS (
    select ARRAY[10524],1,10524,0
  UNION ALL
    select array_append(fullpath,target),pathseq+1,target,total_cost+cost from path join line on(source=node) where node!=10379 and pathseq<=8
)
SELECT * FROM path where fullpath @> ARRAY[10379] order by total_cost limit 1000;
                                                              QUERY PLAN                                                              
--------------------------------------------------------------------------------------------------------------------------------------
 Limit  (cost=277.18..277.18 rows=1 width=44) (actual time=9.992..10.001 rows=8 loops=1)
   CTE line
     ->  Seq Scan on testpath  (cost=0.00..16.45 rows=1045 width=12) (actual time=0.017..0.624 rows=1045 loops=1)
   CTE path
     ->  Recursive Union  (cost=0.00..257.09 rows=161 width=44) (actual time=0.003..9.889 rows=42 loops=1)
           ->  Result  (cost=0.00..0.01 rows=1 width=44) (actual time=0.001..0.002 rows=1 loops=1)
           ->  Hash Join  (cost=0.29..25.39 rows=16 width=44) (actual time=0.451..1.090 rows=5 loops=9)
                 Hash Cond: (line.source = path_1.node)
                 ->  CTE Scan on line  (cost=0.00..20.90 rows=1045 width=12) (actual time=0.003..0.678 rows=1045 loops=8)
                 ->  Hash  (cost=0.25..0.25 rows=3 width=44) (actual time=0.007..0.007 rows=3 loops=9)
                       Buckets: 1024  Batches: 1  Memory Usage: 8kB
                       ->  WorkTable Scan on path path_1  (cost=0.00..0.25 rows=3 width=44) (actual time=0.001..0.004 rows=3 loops=9)
                             Filter: ((node <> 10379) AND (pathseq <= 8))
                             Rows Removed by Filter: 1
   ->  Sort  (cost=3.63..3.64 rows=1 width=44) (actual time=9.991..9.994 rows=8 loops=1)
         Sort Key: path.total_cost
         Sort Method: quicksort  Memory: 26kB
         ->  CTE Scan on path  (cost=0.00..3.62 rows=1 width=44) (actual time=7.851..9.979 rows=8 loops=1)
               Filter: (fullpath @> '{10379}'::integer[])
               Rows Removed by Filter: 34
 Planning time: 0.234 ms
 Execution time: 10.111 ms
(22 rows)

Time: 10.973 ms
```

## 大数据集的对比

以上测试的数据集比较小，只有1000多个边，如果在100w的数据集下，结果如何呢？

计算最短路径|时间(秒)
------------|--------
pgr_dijkstra()|52秒
递归CTE(最大深度2边)|2秒
递归CTE(最大深度3边)|5秒
递归CTE(最大深度4边)|105秒
递归CTE(最大深度5边)|算不出来，放弃
递归CTE(最大深度7边，假设每个边cost相等，不排序，结果最短路径为3个边)|1.6秒


## 小结

简单的深度遍历求解可以适用于小数据集或深度比较小的场景。
在满足这些条件的场景下，效果还是不错的。
