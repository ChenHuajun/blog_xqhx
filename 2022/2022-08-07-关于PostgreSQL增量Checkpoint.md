# 关于PostgreSQL增量Checkpoint

## 为什么PG没有支持增量Checkpoint
众所周知，PG不支持增量checkpoint，所有checkpoint是全量checkpoint，这带来的问题有3个：
1. 响应延迟波动较大
2. 吞吐量波动较大
   由于checkpoint后，第一次修改页面时需要在WAL中记录FPI(full page image)，因此要适当拉大2次checkpoint的间隔，减少FPI的输出。
3. 宕机恢复时，需要从前一次checkpoint开始回放WAL，如果2次checkpoint间的WAL输出很多，会导致恢复时间较长。（即2和3是互相制约的）

而其他数据库比如MySQL支持增量checkpoint，也有人提出PG上checkpoint（附录: Incremental checkopints），但是没有继续下去，相关讨论观点如下：
1. 增量checkpoint有助于减少响应延迟
2. 增量checkpoint可能会增加写入的page量，导致总的事务处理吞吐量下降
3. 实现上需要一些信息，比如每个页面上记录最早弄脏这个页面的事务LSN（当前记录的是最新修改这个页面的事务LSN）

其实，从实现上考虑，最不好处理的是FPI，如果还是使用full page write预防半页写，那么改成增量checkpoint后，FPI的输出就太频繁了。所以要实现增量checkpoint必须放弃full page write，改用其它方案防止半页写，比如MySQL的double write。

简单来讲，实现成本较高，收益的衡量基准不明确。

## 如何实现增量Checkpoint
openGauss实现了增量checkpoint，它的实现方法对PG非常有借鉴意义，其方案大致如下：
1. 新加一个pagewrite线程，用于根据脏页的LSN顺序，刷脏页，默认1分钟启动一次增量checkpoint。
2. pagewrite做完一次增量刷脏页，通知checkpoint线程生成checkpoint WAL记录（增量checkpoint模式下checkpoint线程仅仅写WAL日志）
3. 使用double write代替full page write

详细参考这个视频
- [openGauss的干货第十六期——openGauss检查点、双写及缓存原理介绍](https://www.bilibili.com/video/av295879729/)

根据我们对openGauss和PG的benchmark实测结果，确实也体现了增量checkpoint的好处。
1. openGauss的TPMC曲线以及资源消耗曲线更平滑
2. 压测期间openGauss产生的WAL日志量更小

## 附录: Incremental checkopints

https://www.postgresql.org/message-id/flat/4E3303EA.6000602%402ndQuadrant.com#0101ebbac934e4b36cb6247184e5e935
```
2011/7/29 Greg Smith <greg(at)2ndquadrant(dot)com>:
> 1) Postponing writes as long as possible always improves the resulting
> throughput of those writes.  Any incremental checkpoint approach will detune
> throughput by some amount.  If you make writes go out more often, they will
> be less efficient; that's just how things work if you benchmark anything
> that allows write combining.  Any incremental checkpoint approach is likely
> to improve latency in some cases if it works well, while decreasing
> throughput in most cases.



Agreed.  I came to the same conclusion a while back and then got
depressed.  That might mean we need a parameter to control the
behavior, unless we can find a change where the throughput drop is
sufficiently small that we don't really care, or make the optimization
apply only in cases where we determine that the latency problem will
be so severe that we'll certainly be willing to accept a drop in
throughput to avoid it.



> 2) The incremental checkpoint approach used by other databases, such as the
> MySQL implementation, works by tracking what transaction IDs were associated
> with a buffer update.  The current way PostgreSQL saves buffer sync
> information for the checkpoint to process things doesn't store enough
> information to do that.  As you say, the main price there is some additional
> memory.



I think what we'd need to track is the LSN that first dirtied the page
(as opposed to the current field, which tracks the LSN that most
recently wrote the page).  If we write and flush all pages whose
first-dirtied LSN precedes some cutoff point, then we ought to be able
to advance the redo pointer to that point.
```