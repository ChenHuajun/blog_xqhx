## 1. PostgreSQL中如何对字符数据按字节长度截断

这类似Oracle的substrb的功能，需要将PostgreSQL的字符数据按字节长度截断，但又不允许出现一个中文字符被截了一半的情况。

解决方法之一是安装orafce插件，里面会带兼容Oracle的substrb函数。但是这个方法侵入性太大，不建议随便安装插件，特别是第3方插件。

那么能不能通过纯SQL实现这个功能呢？

首先看下UTF-8编码的规律。UTF-8是一种变长字节编码方式。对于某一个字符的UTF-8编码，如果只有一个字节则其最高二进制位为0；如果是多字节，其第一个字节从最高位开始，连续的二进制位值为1的个数决定了其编码的位数，其余各字节均以10开头。UTF-8理论上最多可用到6个字节，但是实际上最多也就用到3个字节。 （https://blog.csdn.net/urbanvice/article/details/39344343）

```
1字节 0xxxxxxx 
2字节 110xxxxx 10xxxxxx 
3字节 1110xxxx 10xxxxxx 10xxxxxx 
4字节 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx 
5字节 111110xx 10xxxxxx 10xxxxxx 10xxxxxx 10xxxxxx 
6字节 1111110x 10xxxxxx 10xxxxxx 10xxxxxx 10xxxxxx 10xxxxxx 
```

从上可知，凡是'10'开头的字节都不是UTF-8字符的起始字节。根据这个规律，可以判断截断位置的字节是否是UTF-8字符中间字节，找到合适的截断位置。

示例如下，将字符串'中文'按最大长度4字节截断，返回结果为'中'。

```
SELECT
  CASE
    WHEN octet_length(a) > 4 THEN CASE
      WHEN get_byte(convert_to(a, 'UTF-8'), 4) :: bit(8) & B'11000000' <> B'10000000' THEN --截断位置的后一个字节是UTF8字符的起始字节
        convert_from(substring(convert_to(a, 'UTF-8'), 1, 4), 'UTF-8')
      ELSE CASE
        WHEN get_byte(convert_to(a, 'UTF-8'), 4 - 1) :: bit(8) & B'11000000' <> B'10000000' THEN --截断位置的前一个字节是UTF8字符的起始字节
          convert_from(substring(convert_to(a, 'UTF-8'), 1, 4 - 1), 'UTF-8')
        ELSE --当前UTF8字符最多3个字节，即最多2个10开头的字节
          convert_from(substring(convert_to(a, 'UTF-8'), 1, 4 - 2), 'UTF-8')
      END
    END
    ELSE a
  END
FROM
  (
    VALUES(('中文'::text))
  ) t(a);
```

## 2. 查询死元组率最大的表（TOP 20）
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

所以评估表和索引有没有膨胀不能完全通过死元组数量，需要通过专门评估表膨胀的SQL。

## 3. 查询膨胀导致浪费空间最多的表（TOP 20）
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

检查表膨胀和下面的索引膨胀的SQL参考自下面的文章并略有修改

- http://www.postgres.cn/v2/news/viewone/1/622


## 4. 查询膨胀最严重的索引（TOP 20）

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

## 5. 活动会话
```
select
  pid,
  datname,
  usename,
  client_addr,
  state,
  wait_event,
  pg_blocking_pids(pid),
  xact_start,
  query_start,(now() - xact_start)::text xact_runtime,
  application_name,
  backend_type,
  a.query
from
  pg_stat_activity a
where
  pid <> pg_backend_pid()
  and state <> 'idle'  
order by
  xact_start;
```

## 6. 锁
```
select
  l.pid,
  pg_blocking_pids(l.pid),
  l.locktype,
  d.datname,
  n.nspname,
  c.relname,
  l.page,
  l.tuple,
  l.virtualxid,
  l.transactionid,
  l.classid,
  l.objid,
  l.objsubid,
  l.mode,
  l.granted,
  a.query
from
  pg_locks l
  left join pg_database d on(l.database = d.oid)
  left join pg_class c on(l.relation = c.oid)
  left join pg_namespace n on(c.relnamespace = n.oid)
  join pg_stat_activity a on(l.pid = a.pid)
where
  l.pid in (
    select
      pid
    from
      pg_locks
    where
      not granted
  )
  or l.pid in (
    select
      unnest(pg_blocking_pids(pid))
    from
      pg_locks
    where
      not granted
  )
order by
  pid;
```

## 7. 删除指定用户的缺省权限
删除用户时，如果该用户存在相关的缺省权限，将会报错。通过以下SQL生成删除这些缺省权限的SQL。

```
select
    'alter default privileges' || case when dp.schema is null then '' else ' in schema "' || dp.schema || '"' end || ' for user "' || dp.owner || '" revoke all on ' || dp.object || ' from "' || dp.grantee || '";'
from
    (
    select
        pg_get_userbyid(d.defaclrole) as "owner",
        n.nspname as "schema",
        case
            d.defaclobjtype
            when 'r' then 'tables'
            when 'S' then 'sequences'
            when 'f' then 'functions'
            when 'T' then 'types'
            when 'n' then 'schemas'
        end as "object",
        (regexp_split_to_array(unnest(d.defaclacl)::text, '='))[1] as "grantee"
    from
        pg_default_acl d
    left join pg_namespace n on
        n.oid = d.defaclnamespace) dp
where
    dp.grantee = '需要删除的用户的用户名';
```

## 8. 控制特定SQL的并发度
有些场景下需要控制某个SQL在数据库端执行的并发度，防止负载过高，影响其他业务。
并且，从应用客户端可能不太好控制，比如客户端不止一台，并且数量还经常会变化。
此时可用通过以下方式，在数据库测控制某个SQL最大并发数（比如8），超过的会话将一直等待。

```
DO
$$
BEGIN
	<<getlock>>
	LOOP 
		FOR i IN 1..8 LOOP 
			IF  pg_try_advisory_xact_lock(1234567, i) THEN
				EXIT getlock;
			END IF;
		END LOOP;
		perform pg_sleep(1);
	END LOOP;

	执行SQL;
END$$;
```
注：上面1234567是个魔法数字，只要随便取一个不容易冲突的值即可。
 