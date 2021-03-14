# 《Next generation of GIN》解读

PGConf.EU-2013的一篇名叫《Next generation of GIN》的PPT（作者Alexander Korotkov和Oleg Bartunov）中提到了GIN的几个优化，对GIN的性能都有很大提升。概括起来主要有3点。

## 1.压缩存储
原来GIN索引的posting list(或posting tree)中每个ItemPointer占6个字节，通过下面的方法最终可以压缩到2～3个字节。

- varbyte编码(也就是protocol buffer中的variable-length encoding)
- 存储块号的增量而不是实际块号

## 2. frequent\_entry & rare_entry时的快速扫描
当1个频繁的key和1个稀少的key做逻辑与条件查询时，原来要分别把它们的索引项目取出来再做与操作。由于频繁的key匹配的项目太多，导致了大量的Page访问。优化后先从匹配项目最少的索引入手，再到其它索引里查找这些项目有没有同时出现在其它索引里，有的话则匹配否则不匹配。

## 3. 类KNN的GIN索引扫描
这个叫法是基于我对这个优化的理解起的名字。

看下面这个TopN查询的例子。

	postgres=# explain analyze
	SELECT docid, ts_rank(text_vector, to_tsquery('english', 'title')) AS rank
	FROM ti2
	WHERE text_vector @@ to_tsquery('english', 'title')
	ORDER BY rank DESC
	LIMIT 3;
	Limit (cost=8087.40..8087.41 rows=3 width=282) (actual time=433.750..433.752 rows=3 loops=1)
	 -> Sort (cost=8087.40..8206.63 rows=47692 width=282)
	(actual time=433.749..433.749 rows=3 loops=1)
	 Sort Key: (ts_rank(text_vector, '''titl'''::tsquery))
	 Sort Method: top-N heapsort Memory: 25kB
	 -> Bitmap Heap Scan on ti2 (cost=529.61..7470.99 rows=47692 width=282)
	(actual time=15.094..423.452 rows=47855 loops=1)
	 Recheck Cond: (text_vector @@ '''titl'''::tsquery)
	 -> Bitmap Index Scan on ti2_index (cost=0.00..517.69 rows=47692 width=0)
	(actual time=13.736..13.736 rows=47855 loops=1)
	 Index Cond: (text_vector @@ '''titl'''::tsquery)
	Total runtime: 433.787 ms

上面的执行计划中，为了计算相似度，把大量的匹配记录（47855）从堆里读了出来，从而引起了大量的Page读影响处理速度。
优化思路是在GIN的posting list(或posting tree)里加入一些信息，在这里就是，关键字的位置和权重。
这样计算相似度时，不需要再读堆，相似度计算完后只取最匹配的3条记录，所以最多只要进行3次堆表的Page访问。
Patch修改后的效果如下。

	Limit (cost=20.00..21.65 rows=3 width=282) (actual time=18.376..18.427 rows=3 loops=1)
	 -> Index Scan using ti2_index on ti2 (cost=20.00..26256.30 rows=47692 width=282)
	(actual time=18.375..18.425 rows=3 loops=1)
	 Index Cond: (text_vector @@ '''titl'''::tsquery)
	 Order By: (text_vector >< '''titl'''::tsquery)
	Total runtime: 18.511 ms

根据作者的测试，使用了这个Patch之后，一些全文检索的场景下性能可提升10多倍，比Sphinx还快。
但是由于要在索引里追加东西，会增加索引的大小，有些场景也会有反作用。

目前上面1和2的改进早已经合并到PostgreSQL 9.4里了，这使得GIN成为索引重复值很多的数据字段的利器（占用存储空间小，多条件组合的支持好）；但第3个目前还没有加到主分支，可能方案还需进一步完善吧。


## 参考
- http://www.sai.msu.su/~megera/postgres/talks/Next%20generation%20of%20GIN.pdf
- http://www.sai.msu.su/~megera/postgres/talks/hstore-dublin-2013.pdf
- http://www.pgcon.org/2014/schedule/attachments/329_PGCon2014-GIN.pdf
- http://www.infoq.com/cn/news/2015/05/PostgreSQL-Lateral-Max
- http://www.oschina.net/question/12_132079?sort=default&p=1
- http://obartunov.livejournal.com/175235.html

