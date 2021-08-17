# PostgreSQL中实现单双字符模糊匹配

## 前言

SQL中我们可以用like执行前缀，后缀和中缀三种不同的模糊匹配。实际应用时，为了加快搜索我们可能希望创建合适的索引，避免全表扫描。关系数据库中常规的btree索引只能适用于前缀匹配，但是如果我们用的是世界上最高级的开源数据库PostgreSQL，则这三种匹配都可以通过索引轻松应付。

| 匹配类型 | 表达式示例      | 适用索引             | 适配表达式                        | 备注                                                         |
| -------- | --------------- | -------------------- | --------------------------------- | ------------------------------------------------------------ |
| 前缀     | c1 like 'abc%'  | bree(c1)             | c1 like 'abc%'                    | 数据库的collate必须等于C ，否则需要指定操作符类，比如text_pattern_ops |
| 后缀     | c1 like '%abc'  | btree(reverse(c1))   | reverse(c1) like  reverse('%abc') | 数据库的collate必须等于C，否则需要指定操作符类，比如text_pattern_ops |
| 中缀     | c1 like '%abc%' | gin(c1 gin_trgm_ops) | c1 like '%abc%'                   | 需要安装`pg_trgm`插件，并且数据库的ctype不等于C              |

上面的中缀匹配使用了`pg_trgm`插件，`pg_trgm`的原理是把文本拆成若干三元组，然后在这些三元组的集合上构建gin或gist索引。`pg_trgm`也适用于前缀和后缀like匹配，但是效率没有btree高。

`pg_trgm`的拆词示例如下： 

```
postgres=# select show_trgm('abcde');
            show_trgm
---------------------------------
 {"  a"," ab",abc,bcd,cde,"de "}
(1 row)
```

但是需要注意的是，`pg_trgm`存在一个很大的限制，中缀匹配时，查询的值必须包含3个以上的字符。这一限制对于英文数据可以理解，英文只有26个字符，单个字符以及2个字符组合的过滤效果都不理想，走索引的价值也不大。但对于中文就不一样了，中文常用字有3500多个，双字组合的过滤效果一般就很好了。对于生僻字，单个字也具有很好的过滤性。并且，对于中文数据，我们必须要支持单字和双字的模糊匹配。

## 示例

表定义和数据准备

```
create table tb1(id int,c1 text);
insert into tb1 select id,string_agg(chr(19968+(random()*300)::int),'') from generate_series(1,1000000)id,generate_series(1,20)a group by id;
insert into tb1 values(0,'甲乙');
```

查询SQL

```
select count(*) from tb1 where c1 like '%甲乙%';
```



## 解决方案1

把字符转成单个字符的数组，在数组上创建gin索引。

```
create index on tb1 using gin(regexp_split_to_array(c1,''));
```

然后在原始查询后面加上数组匹配条件加速查询

```
select count(*) from tb1 where c1 like '%甲乙%' and regexp_split_to_array(c1,'') @> regexp_split_to_array('甲乙','');
```

**注意事项**

这种方法相当于一元分词，对于英文这种单个字符的值空间很小的数据，失去了索引的价值，只适用于纯中文的模糊匹配。并且对于2个以上字组成词的搜索，搜索效率相对其他方式也差一些。



## 解决方案2

把字符转成二进制再转成字符编码，再在上面创建索引

```
create extension pg_trgm;
create index on tb1 using gin((c1::bytea::text) gin_trgm_ops);
```

这方式转换后的数据形式如下

```
db=# select '甲乙'::bytea::text;
      text
----------------
 \xe794b2e4b999
(1 row)
```

然后在原始查询后面加上相应的匹配条件加速查询

```
select count(*) from tb1 where c1 like '%甲乙%' and c1::bytea::text like '%' || ltrim('甲乙'::bytea::text,'\x') || '%';
```

**注意事项**

- 这个方案，把原来的一个中文字符重新编码成6个英文字符，导致`pg_trgm`拆出来的词元数是原来的6倍，会增加索引的大小，查询效率也会有一定影响
- 需要确保参数`bytea_output`的值为hex



## 解决方案3

前面的2个方案的效率都存在一定问题，如果我们希望得到更好的分词效果，可以在方案1的基础上改进，但是使用自定义的拆词的函数，将输入字符串拆成单字和双字数组的并集。示例如下

创建拆词函数

```
create or replace function split_to_bigm_array(q text,include_one_char bool default false) returns text[] as $$      
declare      
  res text[];      
begin
  if include_one_char then
     res := regexp_split_to_array(q,'');
  else
     res := array[]::text[];
  end if;
   
  for i in 1..length(q)-1 loop      
    res := array_append(res, substring(q,i,2)); 
  end loop;

  select array_agg(distinct a) from unnest(res) a into res;

  return res;
end;
$$ language plpgsql strict immutable;
```

创建索引

```
create index on tb1 using gin(split_to_bigm_array(c1));
```

执行查询

```
select count(*) from tb1 where c1 like '%甲乙%' and split_to_bigm_array(c1) @> split_to_bigm_array('甲乙');
```

一般我们是不会搜索单个字符的，如果需要搜索单个字符，需要把上面的`split_to_bigm_array(c1)`改成`split_to_bigm_array(c1,true)`。这样做得副作用是拆出来的词元，也就是索引项，会增加一倍。



## 解决方案4

以上方案都是只使用PG原生功能，如果考虑第3方方案还可以使用pgbigm或者PGroonga，下面介绍下 pgbigm的用法。

创建索引

```
create extension pg_bigm;
create index on tb1 using gin(c1 gin_bigm_ops);
```

执行查询

```
select count(*) from tb1 where c1 like '%甲乙%';
```



## 方案对比

在普通的全表扫描方式下，这个查询SQL耗时146ms。使用上面的不同索引方案后，效果如下

| 方案  | 索引创建时间（ms） | 索引大小（MB） | 查询速度（ms） | 备注                         |
| ----- | ------------------ | -------------- | -------------- | ---------------------------- |
| 方案1 | 14372              | 26             | 1.843          | 包含高频字时性能会明显下降   |
| 方案2 | 22261              | 79             | 2.621          | 分拆的词元较多，性能略有影响 |
| 方案3 | 38197              | 99             | 1.858          | 需要自定义函数               |
| 方案4 | 20501              | 103            | 1.652          | 依赖第三方插件，不需要改SQL  |

上面的数据显示几种方案的效果都不错。但是，测试用的搜索条件中没有包含高频字，包含高频字时方案1的性能应该会非常差。其他三种方案的适应性应该相对较好，具体可在实际的数据进行验证。



## 参考

- [PostgreSQL 模糊查询最佳实践 - (含单字、双字、多字模糊查询方法)](https://github.com/digoal/blog/blob/61bbe29d6f06bb9b98b7a694f2180ffd33987835/201704/20170426_01.md)

- [PostgreSQL 模糊查询、相似查询 (like '%xxx%') pg_bigm 比 pg_trgm 优势在哪?](https://github.com/digoal/blog/blob/61bbe29d6f06bb9b98b7a694f2180ffd33987835/202009/20200912_01.md)

- http://pgbigm.osdn.jp/pg_bigm_en-1-2.html

- https://pgroonga.github.io/overview/



