## 问题

用户往某一个PostgreSQL库里导数据，由于数据太多，导致磁盘满并引发crash。
之后重启数据后，发现数据库里残留了很多不被任何表引用的数据文件（孤儿数据文件）。

发生这一现象的前提条件是，用户在一个事务中创建了表，随后在这个事务结束之前数据库发生crash。


## 示例

连接到数据库，开启事务，建表并插入数据
```
postgres=# begin;
BEGIN
postgres=*#  create table tb1(id int);
CREATE TABLE
postgres=*# insert into tb1 select generate_series(1,1000000);
INSERT 0 1000000
postgres=*# select pg_relation_filepath('tb1');
 pg_relation_filepath
----------------------
 base/5/127785
(1 row)
```

检查数据文件
```
[postgres@mdw data16pc]$ ll base/5/127785
-rw------- 1 postgres postgres 36249600 Sep  7 00:37 base/5/127785
```

强行`kill -9`这个会话,再重启数据库。事务中创建的表已被回滚。
```
postgres=# \d tb1
Did not find any relation named "tb1".
```
但是，数据文件依然残留
```
[postgres@mdw data16pc]$ ll base/5/127785
-rw------- 1 postgres postgres 36249600 Sep  7 00:37 base/5/127785
```


## 原因

这个是社区已知问题。下面这个邮件中有讨论

https://www.postgresql.org/message-id/flat/CAFzLwcxybFZ-FNiPrzrfwYAwfDg-XoUwxx9Ys0xSaYO5fx%2BJ6Q%40mail.gmail.com#20f919dc71d0bf2b5f1498d920caee8b

Tom Lane对此的解释如下：

```
Yeah, it's entirely intentional that we don't try to clean up orphaned
disk files after a database crash.  There's a long discussion of this and
related topics in src/backend/access/transam/README.  What that says about
why not is that such files' contents might be useful for forensic analysis
of the crash, and anyway "Orphan files are harmless --- at worst they
waste a bit of disk space".  A point not made in that text, but true
anyway, is that it'd also be quite expensive to search a large database
for orphaned files, so people would likely not want to pay that price
on the way to getting their database back up.
```

以下是机器翻译：
```
是的，我们完全有意在数据库崩溃后不尝试清理孤立的磁盘文件。
在 src/backend/access/transam/README 中有一个关于这个和相关主题的长时间讨论。这说明
为什么不这样做是因为这些文件的内容可能
对崩溃的取证分析有用，而且无论如何“孤立文件是无害的——最坏的情况是它们
浪费了一点磁盘空间”。该文本中没有提到但
无论如何都是正确的一点是，在大型数据库中搜索孤立文件也会非常昂贵
，因此人们可能不想在备份数据库的过程中付出这个代价。
```

## 检查孤儿数据文件

```
select * from pg_ls_dir( current_setting('data_directory') || '/base/' || 
                         (select oid::text from pg_database where datname=current_database())) as file 
where file ~ '^[0-9]+(\.[0-9]+)?$'
and split_part(file,'.',1) not in (select relfilenode::text from pg_class );
```

## 对策

建表和导数据不要放在一个事务里，这样即使出现孤儿数据文件，也只是一个空文件，浪费的资源有限（一个inode而已）。

注意：PG 14以后，数据库crash重启后，会自动清空残留的临时表，所以这个孤儿数据文件残留主要指普通的表。



## 参考
- [PostgreSQL中的孤儿文件(orphaned data files)](https://www.cnblogs.com/abclife/p/13948101.html)
- [Re: Orphaned relations after crash/sigkill during CREATE TABLE](https://www.postgresql.org/message-id/flat/CAFzLwcxybFZ-FNiPrzrfwYAwfDg-XoUwxx9Ys0xSaYO5fx%2BJ6Q%40mail.gmail.com#20f919dc71d0bf2b5f1498d920caee8b)
