## 1. 概要

PostgreSQL中被删除的行或被更新的行的旧版本并不会立即消失，而是被打上特殊的“删除”标志位后仍然暂存在数据文件中。
随后由autovacuum后台进程对这些被删除的行，即“死元组”，进行回收。
这是PostgreSQL实现MVCC的独特机制，它非常依赖于autovacuum能够正常的工作，否则有可能导致垃圾回收不及时，引起表和索引的过度膨胀。
表和索引膨胀之后，不仅占用磁盘空间变大，而且可能拖慢SQL执行速度。

下面几种情况会影响垃圾回收，因此可以配置合理的参数以及针对性的监控防止垃圾回收不及时。

- 不恰当的autovacuum参数
- 长事务
- 未决状态的2PC事务
- 失效或滞后严重的复制槽

但是，如果膨胀已经发生，我们如何快速检查出来呢？
常规的方式是使用pgstattuple扩展里的函数，但是这个函数会扫描表，不仅慢而且产生的大量IO也可能会影响数据库的正常业务。
下面介绍几个SQL可以从统计信息中快速估算出表膨胀。

## 2. 检查死元组

查询死元组率最大的表（TOP 20）

```
SELECT schemaname, relname tablename, n_dead_tup, n_live_tup, 
       round(n_dead_tup * 100 / (n_live_tup + n_dead_tup),2) AS dead_tup_ratio 
FROM pg_stat_all_tables WHERE n_dead_tup >= 10000 
ORDER BY dead_tup_ratio DESC
LIMIT 20;
```

死元组率异常说明垃圾回收有问题，需要调查原因并处理。
但是死元组率正常并不代表没有膨胀。因为vacuum和autovacuum在回收垃圾时，只会释放数据文件尾部连续的空闲空间。
举个例子来说，如果有一个10GB的数据文件，在偏移量9GB的位置有一个活的元组，即使这个表里只有这一条记录，vacuum和autovacuum最多只能把这个文件收缩到9GB。

所以评估表和索引有没有膨胀不能完全通过死元组数量，可以使用下面的2个SQL

## 3. 检查表膨胀

查询膨胀导致浪费空间最多的表（TOP 20）

```
WITH t1 AS(
  SELECT
         schemaname,
         tablename,
         (23 + ceil(count(*) >> 3))::bigint nullheader,
         max(null_frac) nullfrac,
         ceil(sum((1 - null_frac) * avg_width))::bigint datawidth
  FROM pg_stats
  GROUP BY schemaname,tablename
), t2 AS(
SELECT
     schemaname,
     tablename,
     (datawidth + 8 - (CASE WHEN datawidth%8=0 THEN 8 ELSE datawidth%8 END)) -- avg data len
      + (1 - nullfrac) * 24 + nullfrac * (nullheader + 8 - (CASE WHEN nullheader%8=0 THEN 8 ELSE nullheader%8 END)) avgtuplelen
FROM t1
)
SELECT schemaname,
       tablename,
       reltuples::numeric row_count,
       (relpages * 8/1024) total_mb,
       ((ceil(reltuples * avgtuplelen / 8168)) * 8/1024)::bigint actual_mb,
       ((relpages - ceil(reltuples * avgtuplelen / 8168)) * 8/1024)::bigint  bloat_mb,
       round((1- (ceil(reltuples * avgtuplelen / 8168)) / relpages)::numeric,2) bloat_pct
FROM t2 t, pg_class c,pg_namespace n
WHERE t.schemaname = n.nspname AND
      c.relname = t.tablename AND
      c.relnamespace = n.oid AND
      relpages > 100
ORDER BY bloat_mb DESC
LIMIT 20;
```

## 4. 检查索引膨胀

查询膨胀最严重的索引（TOP 20）

```
WITH btree_index_atts AS (
SELECT
            pg_namespace.nspname,
            indexclass.relname                                                          AS index_name,
            indexclass.reltuples,
            indexclass.relpages,
            pg_index.indrelid,
            pg_index.indexrelid,
            indexclass.relam,
            tableclass.relname                                                          AS tablename,
            (regexp_split_to_table((pg_index.indkey) :: TEXT, ' ' :: TEXT)) :: SMALLINT AS attnum,
            pg_index.indexrelid                                                         AS index_oid
FROM ((((pg_index
      JOIN pg_class indexclass ON ((pg_index.indexrelid = indexclass.oid)))
      JOIN pg_class tableclass ON ((pg_index.indrelid = tableclass.oid)))
      JOIN pg_namespace ON ((pg_namespace.oid = indexclass.relnamespace)))
      JOIN pg_am ON ((indexclass.relam = pg_am.oid)))
WHERE ((pg_am.amname = 'btree' :: NAME) AND (indexclass.relpages > 0))
), index_item_sizes AS (
SELECT
            ind_atts.nspname,
            ind_atts.index_name,
            ind_atts.reltuples,
            ind_atts.relpages,
            ind_atts.relam,
            ind_atts.indrelid                                    AS table_oid,
            ind_atts.index_oid,
            (current_setting('block_size' :: TEXT)) :: NUMERIC   AS bs,
            8                                                    AS maxalign,
            24                                                   AS pagehdr,
            CASE
            WHEN (max(COALESCE(pg_stats.null_frac, (0) :: REAL)) = (0) :: FLOAT)
                  THEN 2
            ELSE 6
            END                                                  AS index_tuple_hdr,
            sum((((1) :: FLOAT - COALESCE(pg_stats.null_frac, (0) :: REAL)) *
            (COALESCE(pg_stats.avg_width, 1024)) :: FLOAT)) AS nulldatawidth
FROM ((pg_attribute
      JOIN btree_index_atts ind_atts
      ON (((pg_attribute.attrelid = ind_atts.indexrelid) AND (pg_attribute.attnum = ind_atts.attnum))))
      JOIN pg_stats ON (((pg_stats.schemaname = ind_atts.nspname) AND (((pg_stats.tablename = ind_atts.tablename) AND
                                                                        ((pg_stats.attname) :: TEXT =
                                                                        pg_get_indexdef(pg_attribute.attrelid,
                                                                                          (pg_attribute.attnum) :: INTEGER,
                                                                                          TRUE))) OR
                                                                        ((pg_stats.tablename = ind_atts.index_name) AND
                                                                        (pg_stats.attname = pg_attribute.attname))))))
WHERE (pg_attribute.attnum > 0)
GROUP BY ind_atts.nspname, ind_atts.index_name, ind_atts.reltuples, ind_atts.relpages, ind_atts.relam,
            ind_atts.indrelid, ind_atts.index_oid, (current_setting('block_size' :: TEXT)) :: NUMERIC, 8 :: INTEGER
), index_aligned_est AS (
SELECT
            index_item_sizes.maxalign,
            index_item_sizes.bs,
            index_item_sizes.nspname,
            index_item_sizes.index_name,
            index_item_sizes.reltuples,
            index_item_sizes.relpages,
            index_item_sizes.relam,
            index_item_sizes.table_oid,
            index_item_sizes.index_oid,
            COALESCE(ceil((((index_item_sizes.reltuples * ((((((((6 + index_item_sizes.maxalign) -
                                                            CASE
                                                                  WHEN ((index_item_sizes.index_tuple_hdr %
                                                                        index_item_sizes.maxalign) = 0)
                                                                        THEN index_item_sizes.maxalign
                                                                  ELSE (index_item_sizes.index_tuple_hdr %
                                                                        index_item_sizes.maxalign)
                                                                  END)) :: FLOAT + index_item_sizes.nulldatawidth)
                                                            + (index_item_sizes.maxalign) :: FLOAT) - (
                                                            CASE
                                                                  WHEN (((index_item_sizes.nulldatawidth) :: INTEGER %
                                                                        index_item_sizes.maxalign) = 0)
                                                                        THEN index_item_sizes.maxalign
                                                                  ELSE ((index_item_sizes.nulldatawidth) :: INTEGER %
                                                                        index_item_sizes.maxalign)
                                                                  END) :: FLOAT)) :: NUMERIC) :: FLOAT) /
                        ((index_item_sizes.bs - (index_item_sizes.pagehdr) :: NUMERIC)) :: FLOAT) +
                        (1) :: FLOAT)), (0) :: FLOAT) AS expected
FROM index_item_sizes
), raw_bloat AS (
SELECT
            current_database()                                                           AS dbname,
            index_aligned_est.nspname,
            pg_class.relname                                                             AS table_name,
            index_aligned_est.index_name,
            (index_aligned_est.bs * ((index_aligned_est.relpages) :: BIGINT) :: NUMERIC) AS totalbytes,
            index_aligned_est.expected,
            CASE
            WHEN ((index_aligned_est.relpages) :: FLOAT <= index_aligned_est.expected)
                  THEN (0) :: NUMERIC
            ELSE (index_aligned_est.bs *
                  ((((index_aligned_est.relpages) :: FLOAT - index_aligned_est.expected)) :: BIGINT) :: NUMERIC)
            END                                                                          AS wastedbytes,
            CASE
            WHEN ((index_aligned_est.relpages) :: FLOAT <= index_aligned_est.expected)
                  THEN (0) :: NUMERIC
            ELSE (((index_aligned_est.bs * ((((index_aligned_est.relpages) :: FLOAT -
                                                index_aligned_est.expected)) :: BIGINT) :: NUMERIC) * (100) :: NUMERIC) /
                  (index_aligned_est.bs * ((index_aligned_est.relpages) :: BIGINT) :: NUMERIC))
            END                                                                          AS realbloat,
            pg_relation_size((index_aligned_est.table_oid) :: REGCLASS)                  AS table_bytes,
            stat.idx_scan                                                                AS index_scans
FROM ((index_aligned_est
      JOIN pg_class ON ((pg_class.oid = index_aligned_est.table_oid)))
      JOIN pg_stat_user_indexes stat ON ((index_aligned_est.index_oid = stat.indexrelid)))
), format_bloat AS (
SELECT
            raw_bloat.dbname                                             AS database_name,
            raw_bloat.nspname                                            AS schema_name,
            raw_bloat.table_name,
            raw_bloat.index_name,
            round(
            raw_bloat.realbloat)                                     AS bloat_pct,
            round((raw_bloat.wastedbytes / (((1024) :: FLOAT ^
                                          (2) :: FLOAT)) :: NUMERIC)) AS bloat_mb,
            round((raw_bloat.totalbytes / (((1024) :: FLOAT ^ (2) :: FLOAT)) :: NUMERIC),
                  3)                                                     AS index_mb,
            round(
            ((raw_bloat.table_bytes) :: NUMERIC / (((1024) :: FLOAT ^ (2) :: FLOAT)) :: NUMERIC),
            3)                                                       AS table_mb,
            raw_bloat.index_scans
FROM raw_bloat
)
SELECT
      format_bloat.database_name                    as datname,
      format_bloat.schema_name                      as nspname,
      format_bloat.table_name                       as relname,
      format_bloat.index_name                       as idxname,
      format_bloat.index_scans                      as idx_scans,
      format_bloat.bloat_pct                        as bloat_pct,
      format_bloat.table_mb,
      format_bloat.index_mb - format_bloat.bloat_mb as actual_mb,
      format_bloat.bloat_mb,
      format_bloat.index_mb                         as total_mb
FROM format_bloat
ORDER BY format_bloat.bloat_mb DESC
LIMIT 20;
```

## 4. 修复表膨胀

修复表膨胀最简单的方法是执行`vacuum full`命令,但是需要注意，在大表上执行此操作时间会很长，而且执行这个操作时会持有表上的ACCESS EXCLUSIVE锁，阻塞业务对表的读和写。

第三方插件`pg_repack`也可以支持在线的数据重组。

## 5. 参考

检查表膨胀和索引膨胀的SQL参考下面的文章并略有修改

- http://www.postgres.cn/v2/news/viewone/1/622
