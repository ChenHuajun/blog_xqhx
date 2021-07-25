# autovacuum_vacuum_cost_limit参数调优

## 前言

对PG使用者而言，垃圾回收是必须要关注的一个话题。这一工作主要由autovacuum后台进程完成，为了让autovacuum能很好的工作，相关的参数调优是必不可少的，主要是下面几个（其他可以用默认值）。

| 参数                            | 默认值 | 说明                                                         |
| ------------------------------- | ------ | ------------------------------------------------------------ |
| autovacuum_vacuum_threshold     | 50     | 控制触发后台vacuum的阈值。触发条件为:死元组数（等于更新和删除的行数）大于autovacuum_vacuum_threshold+元组数*autovacuum_vacuum_scale_factor |
| autovacuum_vacuum_scale_factor  | 0.2    | 同上                                                         |
| autovacuum_analyze_threshold    | 50     | 控制触发后台analyze的阈值。触发条件为:变更元组数（含插入，更新和删除）大于autovacuum_analyze_threshold+元组数*autovacuum_analyze_scale_factor |
| autovacuum_analyze_scale_factor | 0.1    | 同上                                                         |
| autovacuum_vacuum_cost_limit    | 200    | 用于自动`VACUUM`操作中的代价限制值。默认值-1代表使用vacuum_cost_limit值，默认200） |
| autovacuum_vacuum_cost_delay    | 2ms    | 用于自动`VACUUM`操作中的代价延迟值。                         |

autovacuum的参数调优的详细介绍可参考下面

- http://postgres.cn/docs/12/runtime-config-autovacuum.html
- https://www.2ndquadrant.com/en/blog/autovacuum-tuning-basics/
- http://www.postgres.cn/v2/news/viewone/1/387

概括而言，对于大表建议调小`autovacuum_vacuum_scale_factor`和`autovacuum_analyze_scale_factor`，以避免一次垃圾处理的时候过长，或者统计数据更新不及时。也可以简单地把这两个参数值都减半，即分别设为0.1和0.05，避免单独表级别设置。

```
autovacuum_vacuum_scale_factor = 0.1
autovacuum_analyze_scale_factor = 0.05
```

对于`autovacuum_vacuum_cost_limit`和`autovacuum_vacuum_cost_delay`，需要根据存储的IO能力进行调优。其作用是对autovacuum进行限流，防止其占用过多资源影响业务。但是默认值可能和你的硬件能力极不匹配，导致垃圾回收速度跟不上垃圾产生的速度，并产生严重的性能问题。下面重点介绍怎么设置这两个参数。



## autovacuum如何限流

autovacuum限流基于成本计算，并且定义三个基本操作的成本：

```
vacuum_cost_page_hit = 1
vacuum_cost_page_miss = 10
vacuum_cost_page_dirty = 20
```

也就是说，如果页面是从`shared_buffers` 读取的，则计为 1。如果`shared_buffers`在 OS 中找不到并且需要从 OS 读取，则计为 10（它可能仍从OS的buffer中获取）。最后，如果页面被清理弄脏了，它被计为 20。

基于上面的3个常量，我们可以计算出autovacuum工作的代价，并基于代价进行限流。

PG12及以后版本，默认情况下代价限制值为 200，每次清理完成这么多工作时，它都会休眠 2毫秒：

即从理论上，粗略估算其限制的IO上限如下

- 800 MB/s 读取`shared_buffers`（假设它没有脏）
- 80 MB/s 从操作系统读取（可能从磁盘）
- 40 MB/s 写入（被`autovacuum`进程弄脏的页面）

如果我们使用的是SSD存储，上面的限制太低了。

并且，在PG12以前，`autovacuum_vacuum_cost_delay`的默认值是20ms，即IO被限制在只有上面的十分之一，这几乎是过去很多PG新手必踩得一个坑。

另外，当有多个autovacuum工作进程同时运行时，它们共享这个限额（除非在表级别单独设置限流参数）。

## autovacuum限流参数如何调优

autovacuum限流的目的是主要防止autovacuum把有限的IO能力都耗尽了，影响业务SQL的执行。既然这样，我们设置autovacuum限流参数的调优目标应该是两个：

1. 保证垃圾回收及时，即必须快于垃圾产生的速度。
2. IO消耗低于IO设备的容量上限 

举个栗子，如果存储设备的IO吞吐容量是400MB/s，我们想限制autovacuum的IO不超过200MB/s。并且简化模型，只关注从操作系统读取的IO（`vacuum_cost_page_miss`），可以把`autovacuum_vacuum_cost_limit`设置为500。

但是，这个模型只是理论上的，下面设计一个用例，实际测试一下。



## 测试方法环境

**测试环境**

- PostgreSQL 12

- 16C64G虚机

- 500GB SSD云盘(吞吐大约400MB/s)
- shared_buffer:16GB

 

**测试方法**

1. 选择BenchmarkSQL 1000仓库的`bmsql_customer`作为目标测试表（22GB）。

2. 设置autovacuum参数

```
autovacuum_vacuum_scale_factor = 0.1
autovacuum_analyze_scale_factor = 0.05
autovacuum_vacuum_cost_delay = 2ms
log_autovacuum_min_duration = '1s'
```

3. 在不同`autovacuum_vacuum_cost_limit`配置下,更新目标表1/8的数据，触发autovacuum
4. 检查日志中输出的autovacuum性能数据，和OS上观察的实际IO数据



## 测试结果

### 数据更新

```
update bmsql_customer set c_balance=-c_balance where (random()*8)::int = 1;
```

每次更新1/8记录，大约需要60多秒。

| 执行时间 | IO read     | IO write   |
| -------- | ----------- | ---------- |
| 66s      | 300~350MB/s | 250~450MB/ |

### autovacuum性能

不同参数组合下的autovacuum性能数据如下

| autovacuum_vacuum_cost_limit | autovacuum_vacuum_cost_delay | 时间（s） | IO read（MB/s） | IO Write(MB/s) |
| ---------------------------- | ---------------------------- | --------- | --------------- | -------------- |
| 200                          | 20ms                         | 7021      | 1.3             | 2.9            |
| 200                          | 2ms                          | 611       | 14              | 22             |
| 1000                         | 2ms                          | 90        | 100             | 41             |
| 2000                         | 2ms                          | 63        | 142             | 55             |
| 4000                         | 2ms                          | 50        | 180             | 71             |
| 10000                        | 2ms                          | 41        | 237             | 99             |
| 0                            | 0                            | 35        | 255             | 94             |

由以上数据可知：`autovacuum_vacuum_cost_limit`超过2000，限流效果已不明显

### 实际IO消耗对比

以上的IO read和IO write数据来自autovacuum的日志输出，代表从IO读或者往IO写，由于OS到磁盘间有buffer，不是实际的磁盘IO。

下面每次update后，立即执行一次OS buffer清理，再观察autovacuum的性能数据和实际磁盘IO（通过iotop采集）。

清理OS buffer的命令如下

```
echo 3 > /proc/sys/vm/drop_caches
```

测试结果如下

| autovacuum_vacuum_cost_limit | 是否清理      OS缓存 | 时间（s） | IO read (MB/s) | IO write (MB/s) | 实际IO read (MB/s） | 实际IO write (MB/s) |
| ---------------------------- | -------------------- | --------- | -------------- | --------------- | ------------------- | ------------------- |
| 1000                         | 否                   | 91        | 100            | 38              | 0                   | 10~75               |
| 1000                         | 否                   | 128       | 71             | 28              | 100~250             | 10~75               |
| 2000                         | 是                   | 69        | 132            | 54              | 2~25                | 10~110              |
| 2000                         | 否                   | 103       | 83             | 34              | 100~310             | 10~110              |

注：`autovacuum_vacuum_cost_delay`固定为2ms

### 长事务测试

在另一个会话中开启一个不提交的长事务，再次执行上面的测试。

此时受长事务影响，autovacuum无法实际清理死元组，只能每隔`autovacuum_naptime`（默认1分钟）都触发autovacuum并做一次无用功。

| autovacuum_vacuum_cost_limit | autovacuum回数 | 时间（s） | IO read（MB/s） | IO write (MB/s) |
| ---------------------------- | -------------- | --------- | --------------- | --------------- |
| 1000                         | 第一次         | 58        | 153             | 49              |
| 1000                         | 第二次及以后   | 38        | 212             | 0               |
| 2000                         | 第一次         | 37        | 236             | 72              |
| 2000                         | 第二次及以后   | 22        | 357             | 0               |

注：`autovacuum_vacuum_cost_delay`固定为2ms

有以上测试可见

1. 对autovacuum限流非常有必要，否则出现长事务时，autovacuum会不停的消耗大量IO，影响业务。
2. `autovacuum_naptime`不宜设置太小，否则出现长事务时，会加剧IO的消耗，保持默认值1分钟就可以了。



## 小结

autovacuum实际消耗的IO比理论计算的值要小一些（考虑读写本身耗时和IO buffer）。综合考虑，以下配置应该可以满足绝大多数场景。

```
autovacuum_vacuum_scale_factor = 0.1
autovacuum_analyze_scale_factor = 0.05
autovacuum_vacuum_cost_limit = 1000
autovacuum_vacuum_cost_delay = 2ms
```

这个配置下，垃圾回收所需的时间（本测试中是90s或128s）不超过批量update 1/8数据这种极端场景下产生垃圾的时间（66s）的2倍。应对正常来自业务的数据更新，这个垃圾回收速度应该足够应付了。

之前流传的经验值是在使用SSD时，将`autovacuum_vacuum_cost_limit`设置为10000，但之前版本的PG的`autovacuum_vacuum_cost_delay`默认值20ms，因此并不矛盾。另外，这个配置是基于想把autovacuum的IO消耗控制在200MB/s以下这个前提，对于使用性能更高SSD的环境，也可以把这个值再设置高一些（太高也没有必要，只要垃圾回收足够及时即可）。

