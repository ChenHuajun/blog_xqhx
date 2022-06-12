# 关于pgcompacttable

## 1. 概述
pgcompacttable是一个消除PostgreSQL表和索引膨胀的工具, 可避免常规的`vacuum full`带来的长时间的表锁。除了pgcompacttable，还有其他类型工具`pg_repack`和`pg_squeeze`，它们的原理明显不同。

- `pg_repack`
    创建新表再替换，期间的增量数据通过触发器捕获。

    注意点
    - 必须有主键或唯一约束
    - 触发器会显著影响DML性能
    - 需要额外的空间存储中间表的数据


- `pg_squeeze`
创建新表再替换，期间的增量数据通过逻辑订阅捕获。

    注意点
    - 必须有主键或唯一约束
    - 需要额外的空间存储中间表的数据

- pgcompacttable
从表尾部块开始依次UPDATE表的元组，使其移动到前面的有空闲空间的页面上。


## 2. pgcompacttable简化步骤

1. 初始配置

    1.1 查询表膨胀率，确定需要收缩的目标表。
    1.2 选取目标表的更新字段，优先选择长度小的非索引字段。详细参考【3.1 更新字段选取】
    1.3 设置`session_replication_role`避免触发器被触动
        ```
        set session_replication_role to replica;
        ```
2. 移动表元组
 
    2.1 从尾部开始循环更新一批PAGE上的所有元组，最多5个PAGE（MAX_PAGES_PER_ROUND=5），详细参考【3.2 移动表元组】

        ```
        UPDATE ONLY 表名 SET 更新字段=更新字段 WHERE ctid = ANY($1) RETURNING ctid;
        ```

    2.2 检查返回的ctid
        - 如果有ctid大于这一轮的PAGE范围上界，说明这一轮PAGE范围及其前面的PAGE上已经没有空闲空间。回滚这一轮更新，退出循环。
        - 如果有ctid仍在这一轮的PAGE范围，对这些元组重试上面的UPDATE。重试次数不超过一个页面上可存储的最大的元组数，否则异常退出。

    2.3 sleep一会（默认是执行时间的2倍，delay_ratio=2），执行下一轮


3. 重建索引

    如果是PG 12以上版本且没有设置`reindex-replace`,通过`REINDEX INDEX CONCURRENTLY ...`的方式重建索引。
    否则，创建一个名为`pgcompact_index_$$`的临时索引，再通过RENAME的方式替换原索引。


## 3. pgcompacttable相关代码

参考：https://github.com/dataegret/pgcompacttable

### 3.1 更新字段选取
```
sub get_update_column {
...
  my $sth = _dbh->prepare("SELECT quote_ident(attname)
    FROM pg_catalog.pg_attribute
    WHERE
    attnum > 0 AND -- neither system
    NOT attisdropped AND -- nor dropped
    attrelid = (quote_ident(?) || '.' || quote_ident(?))::regclass
    ORDER BY
    -- Variable legth attributes have lower priority because of the chance
    -- of being toasted
    (attlen = -1),
    -- Preferably not indexed attributes
    (
        attnum::text IN (
            SELECT regexp_split_to_table(indkey::text, ' ')
            FROM pg_catalog.pg_index
            WHERE indrelid = (quote_ident(?) || '.' || quote_ident(?))::regclass)),
    -- Preferably smaller attributes
    attlen,
    attnum
    LIMIT 1;");
```

### 3.2 移动表元组

```
sub create_clean_pages_function {
  
  _dbh->do("
CREATE OR REPLACE FUNCTION public.pgcompact_clean_pages_$$(
    i_table_ident text,
    i_column_ident text,
    i_to_page integer,
    i_page_offset integer,
    i_max_tupples_per_page integer)
RETURNS integer
LANGUAGE plpgsql AS \$\$
DECLARE
    _from_page integer := i_to_page - i_page_offset + 1;
    _min_ctid tid;
    _max_ctid tid;
    _ctid_list tid[];
    _next_ctid_list tid[];
    _ctid tid;
    _loop integer;
    _result_page integer;
    _update_query text :=
        'UPDATE ONLY ' || i_table_ident ||
        ' SET ' || i_column_ident || ' = ' || i_column_ident ||
        ' WHERE ctid = ANY(\$1) RETURNING ctid';
BEGIN
    -- Check page argument values
    IF NOT (
        i_page_offset IS NOT NULL AND i_page_offset >= 1 AND
        i_to_page IS NOT NULL AND i_to_page >= 1 AND
        i_to_page >= i_page_offset)
    THEN
        RAISE EXCEPTION 'Wrong page arguments specified.';
    END IF;
    -- Check that session_replication_role is set to replica to
    -- prevent triggers firing
    IF NOT (
        SELECT setting = 'replica'
        FROM pg_catalog.pg_settings
        WHERE name = 'session_replication_role')
    THEN
        RAISE EXCEPTION 'The session_replication_role must be set to replica.';
    END IF;
    -- Define minimal and maximal ctid values of the range
    _min_ctid := (_from_page, 1)::text::tid;
    _max_ctid := (i_to_page, i_max_tupples_per_page)::text::tid;
    -- Build a list of possible ctid values of the range
    SELECT array_agg((pi, ti)::text::tid)
    INTO _ctid_list
    FROM generate_series(_from_page, i_to_page) AS pi
    CROSS JOIN generate_series(1, i_max_tupples_per_page) AS ti;
    <<_outer_loop>>
    FOR _loop IN 1..i_max_tupples_per_page LOOP
        _next_ctid_list := array[]::tid[];
        -- Update all the tuples in the range
        FOR _ctid IN EXECUTE _update_query USING _ctid_list
        LOOP
            IF _ctid > _max_ctid THEN
                _result_page := -1;
                EXIT _outer_loop;
            ELSIF _ctid >= _min_ctid THEN
                -- The tuple is still in the range, more updates are needed
                _next_ctid_list := _next_ctid_list || _ctid;
            END IF;
        END LOOP;
        _ctid_list := _next_ctid_list;
        -- Finish processing if there are no tupples in the range left
        IF coalesce(array_length(_ctid_list, 1), 0) = 0 THEN
            _result_page := _from_page - 1;
            EXIT _outer_loop;
        END IF;
    END LOOP;
    -- No result
    IF _loop = i_max_tupples_per_page AND _result_page IS NULL THEN
        RAISE EXCEPTION
            'Maximal loops count has been reached with no result.';
    END IF;
    RETURN _result_page;
END \$\$;
  ");

  if ($DBI::err) {
    logger(LOG_ERROR, "SQL Error: %s", $DBI::errstr);
    return undef;
  }

  return 1;
}
```
