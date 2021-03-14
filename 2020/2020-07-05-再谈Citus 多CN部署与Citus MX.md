# 再谈Citus 多CN部署与Citus MX

Citus集群由Coordinator(CN节点)和Worker节点组成。CN节点上放元数据负责SQL分发; Worker节点上放实际的分片，各司其职。
但是，Citus里它们的功能也可以灵活的转换。

## 1. Worker as CN

当一个普通的Worker上存储了元数据后，就有了CN节点分发SQL的能力，可以分担CN的负载。
这样的Worker按官方的说法，叫做Citus MX节点。

配置Citus MX的前提条件为Citus的复制模式必须配置为`streaming`。即不支持在多副本的HA部署架构下使用

```
citus.replication_model = streaming
```

然后将普通的Worker变成Citus MX节点

```
select start_metadata_sync_to_node('127.0.0.1',9002);
```

默认情况下，Citus MX节点上也会分配分片。官方的Citus MX架构中，Citus MX集群中所有Worker都是Citus MX节点。

如果我们只想让少数几个Worker节点专门用于分担CN负载，那么这些节点上是不需要放分片的。
可以通过设置节点的shouldhaveshards属性进行控制。

```
SELECT master_set_node_property('127.0.0.1', 9002, 'shouldhaveshards', false);
```

## 2. CN as Worker

Citus里CN节点也可以作为一个Worker加到集群里。

```
SELECT master_add_node('127.0.0.1', 9001, groupid => 0);
```

CN节点作为Worker后，参考表也会在CN上存一个副本，但默认分片是不会存在上面的。
如果希望分片也在CN上分配，可以把CN的shouldhaveshards属性设置为true。

```
SELECT  master_set_node_property('127.0.0.1', 9001, 'shouldhaveshards', true);
```

配置后Citus集群成员如下:
```
postgres=# select * from pg_dist_node;
 nodeid | groupid | nodename  | nodeport | noderack | hasmetadata | isactive | noderole | nodecluster | metadatasynced | shouldhaveshards 
--------+---------+-----------+----------+----------+-------------+----------+----------+-------------+----------------+------------------
      1 |       1 | 127.0.0.1 |     9001 | default  | f           | t        | primary  | default     | f              | t
      3 |       0 | 127.0.0.1 |     9000 | default  | t           | t        | primary  | default     | f              | t
      2 |       2 | 127.0.0.1 |     9002 | default  | t           | t        | primary  | default     | t              | f
(3 rows)
```

把CN作为Worker用体现了Citus的灵活性，但是其适用于什么场景呢？

官方文档的举的一个例子是，本地表和参考表可以Join。

这样的场景我们确实有，那个系统的表设计是：明细表分片，维表作参考表，报表作为本地表。
报表之所以做成本地表，因为要支持高并发访问，但是又找不到合适的分布键让所有SQL都以路由方式执行。
报表做成参考表也不合适，副本太多，影响写入速度，存储成本也高。

那个系统用的Citus 7.4，还不支持这种用法。当时为了支持报表和参考表的Join，建了一套本地维表，通过触发器确保本地维表和参考维表同步。

## 3. 分片隐藏

在Citus MX节点(含作为Worker的CN节点)上，默认shard是隐藏的，即psql的'\d'看不到shard表，只能看到逻辑表。
Citus这么做，可能是担心有人误操作shard表。

如果想在Citus MX节点上查看有哪些shard以及shard上的索引。可以使用下面的视图。

- `citus_shards_on_worker`
- `citus_shard_indexes_on_worker`

或者设置下面的参数

```
citus.override_table_visibility = false
```

## 4. Citus是怎么隐藏分片的？

Citus的plan hook(distributed_planner)中篡改了`pg_table_is_visible`函数，将其替换成`citus_table_is_visible`。
这个隐藏只对依赖`pg_table_is_visible`函数的地方有效，比如psql的`\d`。直接用SQL访问shard表是不受影响的。


```
static bool
ReplaceTableVisibleFunctionWalker(Node *inputNode)
{
...
		if (functionId == PgTableVisibleFuncId())
		{
			...
			functionToProcess->funcid = CitusTableVisibleFuncId();
		...
```

## 5. Citus多CN方案的限制和不足
1. 不能和多副本同时使用
2. Citus MX节点不能访问本地表
3. 不能控制Citus MX节点上不部署参考表


## 6. 参考

- https://yq.aliyun.com/articles/647370
- https://docs.citusdata.com/en/v9.3/arch/mx.html
