
## openGauss增强特性
openGauss内核基于PostgreSQL 9.2.4的演进而来，并且增加了非常多的特性，也解决了很多PG长期以来的痛点问题。
下面列举一些openGauss在内核上的改造。

- 事务快照采用CSN代替活动事务列表
PG的事务快照中包含所有活动事务的事务xid列表，以进行元组的可见性判断。但是在极高的并发场景下，这个活动事务列表会很大，不仅占内存，也耗时间。CSN是按事务提交顺序递增的编号，可以直接用来判断事务的先后关系。CSN通过CSN日志保存，类似于CLOG。
- 64位xid
- 增量检查点
- double write支持可以代替full page write
- 内存池
- 线程池
- 性能诊断增强
  - WDR
  - dbe_perf schema下大量性能监控视图
  - ASP，记录历史活动会话
  - statment_history视图，记录历史慢SQL
- 列存表
- 内存表
- NUMA架构优化
 - proc数组
 - numa绑核
 - wal buffer分区
 - clog分区
- xlog预分配
- 用户资源管理
- 最大可用模式
  备库故障，主库立刻切换成异步复制。其实出于可用性的考虑，通过HA agent从外部降级也可以达到类似的效果，而且还可以防止脑裂，比如patroni。


## 参考

- [openGauss与PostgreSQL的对比](https://blog.opengauss.org/zh/post/shujukujiagouzhimei/opengauss%E4%B8%8Epostgresql%E7%9A%84%E5%AF%B9%E6%AF%94/)
- [如何看待openGauss与postgresql日常使用差异？](https://zhuanlan.zhihu.com/p/364829636)
- [openGauss数据与PostgreSQL的差异对比](https://www.modb.pro/db/101753)
- [聊聊Opengauss的一些增强特性](https://www.modb.pro/db/58238)