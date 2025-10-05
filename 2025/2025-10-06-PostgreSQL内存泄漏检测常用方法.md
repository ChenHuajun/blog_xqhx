## 1. 概述

修改PostgreSQL内核或插件代码，稍有不慎可能引入内存泄漏。
PostgreSQL 使用内存上下文机制来管理内存，不同功能的模块和不同生命周期的数据会存放在不同的内存上下文中，当不再使用这些内存时可以整体释放内存上下文。
在内存上下文上分配的内存的不当堆积也是内存泄漏的一种表现形态，根据内存泄漏发生所在的内存上下文不同，可以把内存泄漏分为以下几种场景。

1. SQL运行时的内存上下文堆积
    - 比如：处理大量元组时分配的内存未及时释放
2. 存储过程运行时的内存上下文堆积
    - 比如：存储过程中变量存储的数据越来越大
3. 事务运行时的内存上下文堆积
    - 事务级对象未及时释放
4. 会话运行时的内存上下文堆积
    - 比如：会话级缓存的对象越来越多
5. 进程级内存泄漏
    - 误用malloc直接分配内存且遗漏释放，插件开发时如果引入第3方库容易发生这种内存泄漏

下面介绍适用于PostgreSQL的常见的内存泄漏检测方法。

## 2. 内存上下文分析

### 2.1 查询当前会话实时内存使用
对于PostgreSQL 14以上版本，可以直接使用 `pg_backend_memory_contexts` 系统视图来查看当前后端进程的详细内存分配。通过分析哪个上下文的 `used_bytes` 或 `total_bytes` 异常高或持续增长，可以快速定位可疑区域。
```sql
-- 查看内存上下文的使用情况，按占用内存排序
SELECT name, level, sum(total_bytes) total_bytes, sum(free_bytes) free_bytes, sum(used_bytes) used_bytes, count(*) AS context_count
FROM pg_backend_memory_contexts
GROUP BY name, level
ORDER BY total_bytes DESC;
```

输出示例如下：
```
                      name                      | level | total_bytes | free_bytes | used_bytes | context_count
------------------------------------------------+-------+-------------+------------+------------+---------------
 CacheMemoryContext                             |     2 |     1048576 |     304592 |     743984 |             1
 index info                                     |     3 |      245440 |      91776 |     153664 |            98
 Timezones                                      |     2 |      104112 |       2672 |     101440 |             1
 TopMemoryContext                               |     1 |       99456 |       5832 |      93624 |             1
 MessageContext                                 |     2 |       65536 |       8752 |      56784 |             1
 ExprContext                                    |     5 |       65536 |      35048 |      30488 |             5
```

### 2.2 查询其他会话的实时内存使用
`pg_backend_memory_contexts`只能查询本会话的内存上下文，如需查询其他会话的内存上下文使用情况，使用下面的函数将内存上下文信息输出到数据库日志文件中。
```
select pg_log_backend_memory_contexts(pid);
```

比如：
```
postgres=# select pg_log_backend_memory_contexts(1216968);
 pg_log_backend_memory_contexts
--------------------------------
 t
(1 row)
```

输出日志如下：
```
chenhj@ubuntu:/data$ tail logfile
2025-10-03 10:34:21.901 CST [1216968] LOG:  level: 3; index info: 2048 total in 2 blocks; 680 free (2 chunks); 1368 used: pg_authid_rolname_index
2025-10-03 10:34:21.901 CST [1216968] LOG:  level: 2; LOCALLOCK hash: 16384 total in 2 blocks; 4664 free (3 chunks); 11720 used
2025-10-03 10:34:21.901 CST [1216968] LOG:  level: 2; WAL record construction: 49760 total in 2 blocks; 6400 free (0 chunks); 43360 used
2025-10-03 10:34:21.901 CST [1216968] LOG:  level: 2; PrivateRefCount: 8192 total in 1 blocks; 608 free (0 chunks); 7584 used
2025-10-03 10:34:21.901 CST [1216968] LOG:  level: 2; MdSmgr: 8192 total in 1 blocks; 7008 free (0 chunks); 1184 used
2025-10-03 10:34:21.901 CST [1216968] LOG:  level: 2; GUCMemoryContext: 24576 total in 2 blocks; 13048 free (3 chunks); 11528 used
2025-10-03 10:34:21.901 CST [1216968] LOG:  level: 3; GUC hash table: 32768 total in 3 blocks; 11696 free (6 chunks); 21072 used
2025-10-03 10:34:21.901 CST [1216968] LOG:  level: 2; Timezones: 104112 total in 2 blocks; 2672 free (0 chunks); 101440 used
2025-10-03 10:34:21.901 CST [1216968] LOG:  level: 2; ErrorContext: 8192 total in 1 blocks; 7952 free (3 chunks); 240 used
2025-10-03 10:34:21.901 CST [1216968] LOG:  Grand total: 1985184 bytes in 290 blocks; 617496 free (395 chunks); 1367688 used
```

### 2.3 使用 GDB 检查实时内存使用

对于低于PostgreSQL 14版本，或者需要更精确分析的情况，可以通过 GDB 调试器连接到运行中的 PostgreSQL 进程，执行特定脚本来打印出完整的 MemoryContext 树状结构和内存消耗详情。


比如，对于低于PostgreSQL 14版本，打印内存上下文详情到数据库日志中。

```
gdb --batch-silent -ex 'call MemoryContextStatsDetail(TopMemoryContext,100)' -p ${后端进程号}
```

但是，上面的GDB命令引用了符号TopMemoryContext，需要编译成DEBUG版或安装debuginfo包(比如：`https://download.postgresql.org/pub/repos/yum/debug/12/redhat/rhel-7-x86_64/`)才能找到`TopMemoryContext`符号


### 2.4 会话级系统表信息缓存精细分析
会话级的`CacheMemoryContext`如果占用很大，说明系统表信息缓存占用过大，可以通过以下方法进行精细分析。

编译时，定义`CATCACHE_STATS`宏，打开系统表信息缓存统计开关，之后每个会话退出前会打印详细系统表信息缓存。

比如：
```
./configure --prefix=/usr/pg18 --enable-debug --enable-cassert CFLAGS="-O0 -g3 -DCATCACHE_STATS"  --without-icu  --without-zlib
```

输出示例如下：
```
2025-09-27 00:43:50.924 CST [643487] DEBUG:  catcache pg_type/2703: 4 tup, 70000 srch, 65996+0=65996 hits, 4004+0=4004 loads, 4000 invals, 0 lists, 0 lsrch, 0 lhits
2025-09-27 00:43:50.924 CST [643487] DEBUG:  catcache pg_type/2704: 2003 tup, 22000 srch, 7998+7999=15997 hits, 2+6001=6003 loads, 4000 invals, 0 lists, 0 lsrch, 0 lhits
2025-09-27 00:43:50.924 CST [643487] DEBUG:  catcache pg_tablespace/2697: 1 tup, 1 srch, 0+0=0 hits, 1+0=1 loads, 0 invals, 0 lists, 0 lsrch, 0 lhits
2025-09-27 00:43:50.924 CST [643487] DEBUG:  catcache pg_statistic/2696: 6000 tup, 6000 srch, 0+0=0 hits, 0+6000=6000 loads, 0 invals, 0 lists, 0 lsrch, 0 lhits
2025-09-27 00:43:50.924 CST [643487] DEBUG:  catcache pg_class/2662: 0 tup, 30000 srch, 22000+0=22000 hits, 8000+0=8000 loads, 8000 invals, 0 lists, 0 lsrch, 0 lhits
2025-09-27 00:43:50.924 CST [643487] DEBUG:  catcache pg_class/2663: 1 tup, 12000 srch, 0+3999=3999 hits, 2000+6001=8001 loads, 8000 invals, 0 lists, 0 lsrch, 0 lhits
2025-09-27 00:43:50.924 CST [643487] DEBUG:  catcache pg_namespace/2685: 2 tup, 10000 srch, 9998+0=9998 hits, 2+0=2 loads, 0 invals, 0 lists, 0 lsrch, 0 lhits
2025-09-27 00:43:50.924 CST [643487] DEBUG:  catcache pg_namespace/2684: 3 tup, 6002 srch, 5999+0=5999 hits, 2+1=3 loads, 0 invals, 0 lists, 0 lsrch, 0 lhits
2025-09-27 00:43:50.924 CST [643487] DEBUG:  catcache pg_index/2679: 12 tup, 8011 srch, 4000+0=4000 hits, 4011+0=4011 loads, 3999 invals, 0 lists, 0 lsrch, 0 lhits
2025-09-27 00:43:50.924 CST [643487] DEBUG:  catcache pg_default_acl/827: 2 tup, 4000 srch, 0+3998=3998 hits, 0+2=2 loads, 0 invals, 0 lists, 0 lsrch, 0 lhits
2025-09-27 00:43:50.924 CST [643487] DEBUG:  catcache pg_database/2672: 1 tup, 3 srch, 2+0=2 hits, 1+0=1 loads, 0 invals, 0 lists, 0 lsrch, 0 lhits
2025-09-27 00:43:50.924 CST [643487] DEBUG:  catcache pg_opclass/2687: 2 tup, 4000 srch, 3998+0=3998 hits, 2+0=2 loads, 0 invals, 0 lists, 0 lsrch, 0 lhits
2025-09-27 00:43:50.924 CST [643487] DEBUG:  catcache pg_authid/2677: 1 tup, 2 srch, 1+0=1 hits, 1+0=1 loads, 0 invals, 0 lists, 0 lsrch, 0 lhits
2025-09-27 00:43:50.924 CST [643487] DEBUG:  catcache pg_authid/2676: 1 tup, 3 srch, 2+0=2 hits, 1+0=1 loads, 0 invals, 0 lists, 0 lsrch, 0 lhits
2025-09-27 00:43:50.924 CST [643487] DEBUG:  catcache pg_attribute/2659: 30 tup, 8028 srch, 0+0=0 hits, 8028+0=8028 loads, 7998 invals, 0 lists, 0 lsrch, 0 lhits
2025-09-27 00:43:50.924 CST [643487] DEBUG:  catcache pg_amproc/2655: 4 tup, 12000 srch, 11996+0=11996 hits, 4+0=4 loads, 0 invals, 0 lists, 0 lsrch, 0 lhits
2025-09-27 00:43:50.924 CST [643487] DEBUG:  catcache pg_am/2652: 2 tup, 28011 srch, 28009+0=28009 hits, 2+0=2 loads, 0 invals, 0 lists, 0 lsrch, 0 lhits
2025-09-27 00:43:50.924 CST [643487] DEBUG:  catcache pg_am/2651: 1 tup, 2000 srch, 1999+0=1999 hits, 1+0=1 loads, 0 invals, 0 lists, 0 lsrch, 0 lhits
2025-09-27 00:43:50.924 CST [643487] DEBUG:  catcache totals: 8070 tup, 222061 srch, 161998+15996=177994 hits, 26062+18005=44067 loads, 35997 invals, 0 lists, 0 lsrch, 0 lhits
2025-09-27 00:43:50.927 CST [643388] DEBUG:  client backend (PID 643487) exited with exit code 0
```

注：PostgreSQl中每创建一个表再删除，会残留4条系统表信息缓存记录，其中1条`pg_type`缓存(toast表的type)，3条`pg_statistic`缓存。创建再删除一个临时表只会残留1条`pg_type`缓存。

如果编译时未指定`CATCACHE_STATS`宏,还可以通过定制的gdb脚本，分析会话的系统表信息缓存。示例如下：

准备GDB脚本catcache.gdb:
```
# 设置变量指向 CacheHdr
set $hdr = CacheHdr

# 检查 CacheHdr 是否为空
if ($hdr == 0)
  printf "CacheHdr is NULL\n"
else
  # 获取链表头
  set $head = &($hdr->ch_caches.head)
  set $node = $head->next
  set $count = 0

  printf "CacheHdr contains %d total tuples\n", $hdr->ch_ntup
  printf "CatCache list:\n"

  # 遍历链表
  while ($node != $head && $node != 0)
    # 使用 slist_container 宏计算 CatCache 地址
    # slist_container(CatCache, cc_next, $node)
    set $cache = (CatCache*)((char*)$node - (size_t)&((CatCache*)0)->cc_next)

    printf "  [%d] id=%d cache=%p reloid=%u indexoid=%u relname=\"%s\" nkeys=%d ntup=%d\n", \
           $count, $cache->id,$cache, $cache->cc_reloid, $cache->cc_indexoid, \
           $cache->cc_relname, $cache->cc_nkeys, $cache->cc_ntup

    set $node = $node->next
    set $count = $count + 1
  end

  printf "Total CatCache entries: %d\n", $count
end
```

gdb attach到目标分析进程，执行gdb脚本。输出示例如下
```
(gdb) source catcache.gdb
CacheHdr contains 214 total tuples
CatCache list:
  [0] id=84 cache=0x579738022680 reloid=1418 indexoid=175 relname="(not known yet)" nkeys=2 ntup=0
  [1] id=83 cache=0x579738022280 reloid=1418 indexoid=174 relname="(not known yet)" nkeys=1 ntup=0
  [2] id=82 cache=0x579738021a00 reloid=1247 indexoid=2703 relname="pg_type" nkeys=1 ntup=17
  [3] id=81 cache=0x579738021200 reloid=1247 indexoid=2704 relname="(not known yet)" nkeys=2 ntup=0
  [4] id=80 cache=0x579738020e00 reloid=3764 indexoid=3767 relname="(not known yet)" nkeys=1 ntup=0
  [5] id=79 cache=0x579738020980 reloid=3764 indexoid=3766 relname="(not known yet)" nkeys=2 ntup=0
  [6] id=78 cache=0x579738020580 reloid=3601 indexoid=3607 relname="(not known yet)" nkeys=1 ntup=0
  [7] id=77 cache=0x579738020100 reloid=3601 indexoid=3606 relname="(not known yet)" nkeys=2 ntup=0
  [8] id=76 cache=0x57973801fd00 reloid=3600 indexoid=3605 relname="(not known yet)" nkeys=1 ntup=0
  [9] id=75 cache=0x57973801f880 reloid=3600 indexoid=3604 relname="(not known yet)" nkeys=2 ntup=0
  [10] id=74 cache=0x57973801f480 reloid=3602 indexoid=3712 relname="(not known yet)" nkeys=1 ntup=0
  [11] id=73 cache=0x57973801f000 reloid=3602 indexoid=3608 relname="(not known yet)" nkeys=2 ntup=0
  [12] id=72 cache=0x57973801ec00 reloid=3603 indexoid=3609 relname="(not known yet)" nkeys=3 ntup=0
  [13] id=71 cache=0x57973801e700 reloid=3576 indexoid=3575 relname="(not known yet)" nkeys=2 ntup=0
  [14] id=70 cache=0x57973801e180 reloid=3576 indexoid=3574 relname="(not known yet)" nkeys=1 ntup=0
  [15] id=69 cache=0x57973801dd80 reloid=1213 indexoid=2697 relname="pg_tablespace" nkeys=1 ntup=1
...
```

## 3. 使用Valgrind工具分析内存泄漏

Valgrind是Linux下用于C/C++程序内存调试和性能分析的开源工具集。其核心原理是通过​​动态二进制插桩技术​​，在虚拟CPU环境中运行程序，先将目标程序的机器代码翻译为中间表示（VEX IR），然后根据所选工具（如Memcheck）插入检测代码。运行时会维护​​Valid-Address和Valid-Value影子位​​来跟踪内存地址的合法性与值的初始化状态，从而精准检测内存泄漏、越界访问、使用未初始化值等问题。
程序执行完毕后，Valgrind会生成详细错误报告。

Valgrind 包含多个工具，Memcheck 是其最常用且默认的工具：

| 工具名称 | 主要功能 |
| :--- | :--- |
| **Memcheck** | **检测内存问题**：如内存泄漏、使用未初始化值、非法读写（越界）、重复释放或错误释放内存等。 |
| **Cachegrind** | **缓存分析器**：模拟 CPU 的 L1/L2 缓存，帮助识别缓存未命中导致的性能瓶颈。 |
| **Callgrind** | **调用分析器**：提供函数调用图及更详细的缓存分析，常与 **KCachegrind** 可视化工具配合使用。 |
| **Helgrind** | **线程调试器**：检测**多线程程序**中的数据竞争（Data Races）、锁顺序问题（Lock Ordering Problems）等同步错误。 |
| **Massif** | **堆分析器**：测量程序使用了多少堆内存，帮助分析内存使用趋势及识别潜在的内存碎片或过度分配问题。 |

## 3.1 编译准备

PostgreSQL使用内置的内存上下文机制分配内存，不直接调用malloc等系统内存分配函数。为正确分析PostgreSQL中的动态内存分配，需要在编译PostgreSQL时定义宏`USE_VALGRIND`，通知Valgrind内存和释放的位置。
同时，为了在报告中看到具体的源代码文件和行号，而不是晦涩的机器地址，在编译时需要加上 `-g` 选项。示例如下：

```
./configure --prefix=/usr/pg18 --enable-debug --enable-cassert CFLAGS="-O0 -g3 -DCATCACHE_STATS -DUSE_VALGRIND"  --without-icu  --without-zlib
```
## 3.2 使用Valgrind的Memcheck工具分析内存泄漏

通过valgrind启动PostgreSQL，使用默认的Memcheck工具。示例如下：
```
valgrind --leak-check=full --show-leak-kinds=all --track-origins=yes --log-file=valgrind.log --trace-children=yes /usr/pg18/bin/postgres -D data18
```

然后运行自定义测试程序，记录对应PostgreSQL会话的pid，等待会话结束或主动终止会话。
从输出日志valgrind.log中找到，对应会话的内存诊断记录。示例如下。
```
==809798== 2,964 (232 direct, 2,732 indirect) bytes in 1 blocks are definitely lost in loss record 18 of 33
==809798==    at 0x4846828: malloc (in /usr/libexec/valgrind/vgpreload_memcheck-amd64-linux.so)
==809798==    by 0xA48F6C: save_ps_display_args (ps_status.c:192)
==809798==    by 0x5A40DD: main (main.c:104)
==809798== 
...
==809798== LEAK SUMMARY:
==809798==    definitely lost: 232 bytes in 1 blocks
==809798==    indirectly lost: 2,732 bytes in 28 blocks
==809798==      possibly lost: 0 bytes in 0 blocks
==809798==    still reachable: 237,776 bytes in 35 blocks
==809798==         suppressed: 0 bytes in 0 blocks
```
Valgrind的Memcheck工具在程序退出后检测内存泄漏。泄漏类型主要包括：
- **Definitely lost**：确认泄漏，内存完全无法访问。
- **Indirectly lost**：间接泄漏，通常因结构体整体泄漏导致。
- **Possibly lost**：可能泄漏，指针指向内存块内部而非开头。
- **Still reachable**：内存仍可访问但未释放，通常在程序退出时被系统回收。

由于PostgreSQL在进程退出时，先释放对应的内存上下文，而后Memcheck工具才检测内存泄漏。
因此对于常见的发生在内存上下文上的内存过度分配，Memcheck没有任何帮助。即Memcheck工具不适用于【概述】中的场景1,2,3,4；但可以检出场景5的问题（使用malloc直接分配内存且遗漏释放）。

**注意事项**
- 由于 Valgrind 在虚拟环境中执行并进行了大量插桩操作，**程序运行速度会大大降低**（通常慢 10-50 倍）。

## 3.3 使用Valgrind的Massif工具分析内存使用趋势

对于场景1,2,3,4，可以使用Massif工具分析内存使用趋势，如果发生内存过量分配，可找到内存分配较大的代码位置。

首先通过valgrind启动PostgreSQL，并使用Massif工具。示例如下：
```
valgrind --tool=massif --time-unit=B --massif-out-file=massif.out.%p /usr/pg18/bin/postgres -D data18
```
上面的`--time-unit=B`代表内存分析报告中时间轴的单位是分配/释放的字节数，短时间运行的程序​​或测试场景，能提供清晰可重现的内存分配视图。

然后运行自定义测试程序，并记录对应PostgreSQL会话的pid，等待会话结束或主动终止会话。
每个会话终止时，会输出内存使用记录到`massif.out.$pid`文件中。调用`ms_print`脚本可以生成可读性比较好的报告。
```
ms_print massif.out.643109 >massif.out.643109.txt
```

### 3.3.1 Massif内存报告内容示例
```
chenhj@chenhj-ubuntu:/data$ head -100 massif.out.643109.txt
--------------------------------------------------------------------------------
Command:            /usr/pg18/bin/postgres -D data18
Massif arguments:   --time-unit=B --massif-out-file=massif.out.%p
ms_print arguments: massif.out.643109
--------------------------------------------------------------------------------


    MB
5.562^                                                                       #
     |                                   @:  : :  :   :   ::::@:::::@::::@:::#
     |                                :::@:::::::::::@:::@::::@:::::@::::@:::#
     |                                :::@::::::: :::@:::@::::@:::::@::::@:::#
     |                                :::@::::::: :::@:::@::::@:::::@::::@:::#
     |                                :::@::::::: :::@:::@::::@:::::@::::@:::#
     |                                :::@::::::: :::@:::@::::@:::::@::::@:::#
     |                                :::@::::::: :::@:::@::::@:::::@::::@:::#
     |                                :::@::::::: :::@:::@::::@:::::@::::@:::#
     |          @::::::@:::::::@::::@::::@::::::: :::@:::@::::@:::::@::::@:::#
     |          @::: ::@:: ::: @::: @ :::@::::::: :::@:::@::::@:::::@::::@:::#
     |          @::: ::@:: ::: @::: @ :::@::::::: :::@:::@::::@:::::@::::@:::#
     |          @::: ::@:: ::: @::: @ :::@::::::: :::@:::@::::@:::::@::::@:::#
     | :::::::::@::: ::@:: ::: @::: @ :::@::::::: :::@:::@::::@:::::@::::@:::#
     | :::::::::@::: ::@:: ::: @::: @ :::@::::::: :::@:::@::::@:::::@::::@:::#
     |::::::::::@::: ::@:: ::: @::: @ :::@::::::: :::@:::@::::@:::::@::::@:::#
     |::::::::::@::: ::@:: ::: @::: @ :::@::::::: :::@:::@::::@:::::@::::@:::#
     |::::::::::@::: ::@:: ::: @::: @ :::@::::::: :::@:::@::::@:::::@::::@:::#
     |::::::::::@::: ::@:: ::: @::: @ :::@::::::: :::@:::@::::@:::::@::::@:::#
     |::::::::::@::: ::@:: ::: @::: @ :::@::::::: :::@:::@::::@:::::@::::@:::#
   0 +----------------------------------------------------------------------->GB
     0                                                                   29.03

Number of snapshots: 97
 Detailed snapshots: [11, 18, 25, 30, 35, 48, 56, 66, 76, 86, 95 (peak)]

--------------------------------------------------------------------------------
  n        time(B)         total(B)   useful-heap(B) extra-heap(B)    stacks(B)
--------------------------------------------------------------------------------
  0              0                0                0             0            0
  1    220,962,728        1,692,664        1,688,680         3,984            0
  2    707,800,680        2,244,488        2,240,448         4,040            0
  3  1,097,325,968        2,211,136        2,207,096         4,040            0
  4  1,377,111,864        2,217,080        2,213,048         4,032            0
  5  2,010,766,296        2,260,968        2,256,912         4,056            0
  6  2,384,916,784        2,233,584        2,229,528         4,056            0
  7  2,883,755,240        2,261,016        2,256,944         4,072            0
  8  3,218,132,840        2,225,400        2,221,336         4,064            0
  9  3,627,323,504        2,271,312        2,267,198         4,114            0
 10  4,223,090,224        2,249,600        2,245,692         3,908            0
 11  4,639,051,856        3,376,624        3,372,564         4,060            0
99.88% (3,372,564B) (heap allocation functions) malloc/new/new[], --alloc-fns, etc.
->70.48% (2,379,776B) 0xA52470: AllocSetAllocFromNewBlock (aset.c:908)
| ->70.48% (2,379,776B) 0xA52B54: AllocSetAlloc (aset.c:1051)
|   ->58.89% (1,988,608B) 0xA64480: palloc (mcxt.c:1342)
|   | ->46.58% (1,572,864B) 0x9F07B2: CatalogCacheCreateEntry (catcache.c:2239)
|   | | ->46.58% (1,572,864B) 0x9EF2EF: SearchCatCacheMiss (catcache.c:1604)
|   | |   ->46.58% (1,572,864B) 0x9EF052: SearchCatCacheInternal (catcache.c:1488)
|   | |     ->46.58% (1,572,864B) 0x9EECCB: SearchCatCache (catcache.c:1346)
|   | |       ->46.58% (1,572,864B) 0xA0F435: SearchSysCache (syscache.c:217)
|   | |         ->46.58% (1,572,864B) 0xA0FA1B: SearchSysCacheExists (syscache.c:433)
|   | |           ->46.58% (1,572,864B) 0x38896E: makeArrayTypeName (pg_type.c:865)
|   | |             ->46.58% (1,572,864B) 0x346BDA: heap_create_with_catalog (heap.c:1374)
|   | |               ->46.58% (1,572,864B) 0x493533: DefineRelation (tablecmds.c:1054)
|   | |                 ->46.58% (1,572,864B) 0x817113: ProcessUtilitySlow (utility.c:1167)
|   | |                   ->46.58% (1,572,864B) 0x816E44: standard_ProcessUtility (utility.c:1070)
|   | |                     ->46.58% (1,572,864B) 0x815D41: ProcessUtility (utility.c:523)
|   | |                       ->46.58% (1,572,864B) 0x814609: PortalRunUtility (pquery.c:1153)
|   | |                         ->46.58% (1,572,864B) 0x814883: PortalRunMulti (pquery.c:1310)
|   | |                           ->46.58% (1,572,864B) 0x813CE2: PortalRun (pquery.c:788)
|   | |                             ->46.58% (1,572,864B) 0x80C2AB: exec_simple_query (postgres.c:1273)
|   | |                               ->46.58% (1,572,864B) 0x811B07: PostgresMain (postgres.c:4766)
|   | |                                 ->46.58% (1,572,864B) 0x807680: BackendMain (backend_startup.c:124)
|   | |                                   ->46.58% (1,572,864B) 0x70587F: postmaster_child_launch (launch_backend.c:290)
|   | |                                     ->46.58% (1,572,864B) 0x70C2E0: BackendStartup (postmaster.c:3587)
|   | |                                       ->46.58% (1,572,864B) 0x709824: ServerLoop (postmaster.c:1702)
|   | |                                         ->46.58% (1,572,864B) 0x709113: PostmasterMain (postmaster.c:1400)
|   | |                                           ->46.58% (1,572,864B) 0x5A4DD9: main (main.c:227)
```

对于 `ms_print` 输出的 Massif 内存分析报告，参考以下方方进行解读。
### 3.3.2 理解报告概览

首先，报告开头会列出基本信息，包括被分析的程序名称、Massif 的运行参数以及 `ms_print` 的命令行参数 。这部分主要用于确认分析环境和条件。

紧接着，你会看到一个由字符构成的**内存使用量随时间变化的曲线图** 。理解这个图需要先了解几个关键概念：

| 图表元素 / 快照类型 | 表示符号 | 含义说明 |
| :--- | :--- | :--- |
| **峰值快照 (Peak Snapshot)** | `#` | 记录了整个程序运行过程中**内存使用量最高的那个时间点** 。这是分析的重点，因为它代表了程序的内存需求高峰。 |
| **详细快照 (Detailed Snapshot)** | `@` | 除了记录内存总量，还保存了详细的**调用栈信息**，可以精确看到是哪些代码分配了内存 。默认每10个快照有一个是详细的。 |
| **普通快照 (Normal Snapshot)** | `:` | 仅记录内存使用量，不包含调用栈细节 。用于勾勒内存变化的整体趋势。 |
| **时间轴 (X轴)** | - | 单位可以是执行的指令数(I)、毫秒(ms)或分配的字节数(B)。对于短时间运行的程序，使用 `--time-unit=B` 选项能让图表更清晰 。 |
| **内存轴 (Y轴)** | - | 显示内存消耗，单位会自动调整（如KB, MB）。图表下方会注明总快照数、详细快照编号以及峰值快照编号 。 |

### 3.3.3 分析快照详细信息

图表之后是每个快照的详细数据表格，这是定位问题的核心。你需要重点关注**峰值快照**（标记为 `(peak)`）的详细信息 。

表格中各列的含义如下：

| 列名 | 含义 |
| :--- | :--- |
| `n` | 快照编号 |
| `time(B)` | 时间点（单位取决于 `--time-unit` 设置） |
| `total(B)` | **总内存使用量**（堆 + 栈 + 其他），这是最关键的指标 |
| `useful-heap(B)` | 程序实际请求的堆内存大小 |
| `extra-heap(B)` | 内存分配器为了**对齐和管理**所消耗的额外字节 |
| `stacks(B)` | 栈内存使用量（需通过 `--stacks=yes` 启用分析） |

在峰值或详细快照下方，会有一个 **“分配树”** 。这个树状结构从下往上读，清晰地展示了内存分配的调用链，可以精准定位到是**哪行代码**分配了内存 。例如：
```
99.88% (3,372,564B) (heap allocation functions) malloc/new/new[], --alloc-fns, etc.
->70.48% (2,379,776B) 0xA52470: AllocSetAllocFromNewBlock (aset.c:908)
| ->70.48% (2,379,776B) 0xA52B54: AllocSetAlloc (aset.c:1051)
|   ->58.89% (1,988,608B) 0xA64480: palloc (mcxt.c:1342)
|   | ->46.58% (1,572,864B) 0x9F07B2: CatalogCacheCreateEntry (catcache.c:2239)
```
这段信息表明，在 `catcache.c` 第2239行的 `CatalogCacheCreateEntry` 函数中，发生了大量内存分配 。

## 小结
PostgreSQL 内存泄漏检测主要方法包括下面几种，多种方法结合，可覆盖从SQL运行时到进程级的不同泄漏场景。
- 利用 pg_backend_memory_contexts系统视图（v14+）或 GDB 分析内存上下文的异常增长；
- 使用 Valgrind 工具集，其中 Memcheck 可检测直接 malloc泄漏，Massif 则分析堆内存分配趋势并定位源头；
- 通过定义 CATCACHE_STATS宏编译，精细分析会话级系统表缓存泄漏。

