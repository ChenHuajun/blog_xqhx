## 问题
业务反馈GaussDB(openGauss)数据库分页查询时，数据记录有丢失。反馈的数据库是GaussDB，但是PostgreSQL的行为是一样的，下面的验证基于PostgreSQL。

## 原因
用户的分页SQL中，用于排序的字段不是唯一的。这种场景下，数据库不保证同一个排序字段值对应的多条记录的输出顺序，实际的输出顺序和数据库的实现有关。
所以当这些记录不能在一个分页全部显示出来时，后面的分页出现数据重复，遗漏等看似奇怪的现象就不足为奇了。

## 演示
测试数据准备
```
create table tb1(id int,c1 int);
insert into tb1 select id, id%10 from generate_series(1,90) id;
```

测试结果如下
```
postgres=# select * from tb1 order by c1 limit 5;
 id | c1
----+----
 40 |  0
 20 |  0
 30 |  0
 10 |  0
 50 |  0
(5 rows)

postgres=# select * from tb1 order by c1 limit 5 offset 5;
 id | c1
----+----
 80 |  0
 40 |  0
 50 |  0
 10 |  0
 21 |  1
(5 rows)
```

省略offset只调整limit，可以看的更清楚。
```
postgres=# select * from tb1 order by c1 limit 1;
 id | c1
----+----
 10 |  0
(1 row)

postgres=# select * from tb1 order by c1 limit 2;
 id | c1
----+----
 10 |  0
 20 |  0
(2 rows)

postgres=# select * from tb1 order by c1 limit 3;
 id | c1
----+----
 20 |  0
 10 |  0
 30 |  0
(3 rows)

postgres=# select * from tb1 order by c1 limit 4;
 id | c1
----+----
 20 |  0
 30 |  0
 10 |  0
 40 |  0
(4 rows
```

## 小结
从上面可知，PG中使用非唯一字段排序进行分页查询时，不同limit和offset值下，输出结果的顺序很可能不一致。
这个问题并不是数据库的bug，要回避这个问题，需要修改SQL，确保分页查询的排序字段（或组合排序字段）唯一。
