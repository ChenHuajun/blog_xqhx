# 1. 前言
MySQL和PostgreSQL是目前主流的两个开源关系数据库，同样都是开源产品，我们该如何选型呢？MySQL长期以来被认为是更加快速但支持的特性较少；而PostgreSQL则提供了丰富的特性经常被描述为开源版的Oracle。MySQL已经由于它的快速和易用变得非常流行，但PostgreSQL正得到越来越多来自Oracel或SQL Server背景的开发人员的追从。
但是很多假设已经变得过时或者不正确了，MySQL已经加入了很多高级特性，PostgreSQL也大大提高了它的速度。本文针对最新的MySQL 5.7 and PostgreSQL 9.5进行对比。

# 2. 约定

* 针对最新的MySQL 5.7社区版和 PostgreSQL 9.5进行对比。
* 鉴于innodb以外的引擎使用较少，主要针对MySQL的innodb引擎。

# 3. 综合比较

##3.1 许可

* MySQL  
MySQL分商业版和社区版，社区版为GPL许可,允许免费使用，但是如果你要分发你的代码，你可以选择开源，或者闭源，如果选择闭源则必须向ORACLE支付费用。

* PostgreSQL  
PostsgreSQL是类BSD许可，允许用户以任何目的免费使用。

## 3.2 开发模式

* MySQL  
MySQL由Oracle主导其开发，开发中的代码不对外公开, 直到新版本发布时才公开源码。Oracle开发团队以外的人可通过[MySQL Bug系统](http://bugs.mysql.com)提交Patch,Oracle开发团队会吸收或改写Patch(Oracle开发团队以外的人没有开发版代码)。另外，代码贡献者需先签署[Oracle Contribution Agreement (OCA)](http://www.oracle.com/technetwork/community/oca-486395.html)才允许提交Patch。

* PostgreSQL  
由来自世界不同公司的开发者组成的PostgreSQL社区主导PostgreSQL的开发，PostgreSQL社区的组织架构参考[Contributor Profiles](http://www.postgresql.org/community/contributors/)。开发过程完全开发，开发版的代码完全公开。任何人随时可以通过[pgsql-hackers邮件列表](http://www.postgresql.org/list/pgsql-hackers)提交Patch。Patch可能会被commiter直接提交到源码树，也可能被要求加入到[Commitfests](https://commitfest.postgresql.org/)以接受Review。通过Commitfests可以了解当前开发版中包含的每个特性以及它们的进度。任何人不仅可以提交Patch，甚至还可以review Commitfests上的Patch。提交PostgreSQL Patch的详细请参考[Submitting a Patch](https://wiki.postgresql.org/wiki/Submitting_a_Patch)

##3.3 社区分支
* MySQL  
MySQL分支较多 ,除了Oracle官方的版本，比较流行的还有Percona Server和MariaDB等。

* PostgreSQL  
PostgreSQL只有一个开源主分支，代码托管在git.postgresql.org。另外，有一些公司发布了基于PostgreSQL增强的企业版产品，比如EnterpriseDB公司的EDB™ Postgres Advanced Server，富士通的Fujitsu Enterprise Postgres等。这些产品都是闭源的商业产品，不属于开源软件的范畴。

##3.4 版本更新
###3.4.1 MySQL  
MySQL的版本号由3组数字组成，比如5.7.1，每个数字的含义如下

	第一个数字(5)是major version，描述了文件格式。所有MySQL 5发布拥有有相同的文件格式。
	第二个数字(7)是release lever。和major version合在一起组成发布系列号(release series number)。
	第三个数字(1)是发布系列号中的version number，每次新版本发布增长，大多数情况下一个系列中最近的version是最佳选择。  
	对小的更新，增长最后的数字。当有大的新特性或者对前一版本有小的不兼容，增长第二个数字，如果文件格式发生了变更，增长第一个数字。

以上翻译自MySQL的官方手册[2.1.1 Which MySQL Version and Distribution to Install](http://dev.mysql.com/doc/refman/5.7/en/which-version.html)。

MySQL的版本系列又分为开发版和General Availability (GA)版，只有GA版适合用于生产环境。  

MySQL的目标是每18~24个月发布一个新发布系列的GA版本，最近几个发布系列的第一个GA版本的发布时间如下。

	MySQL 5.0.15: 2005-10-19
	MySQL 5.1.30: 2008-11-14
	MySQL 5.5.8:  2010-12-03
	MySQL 5.6.10: 2013-02-05
	MySQL 5.7.9:  2015-10-21

**升级方法**  
* In-place升级: 停机，替换MySQL二进制文件，重启MySQL，运行`mysql_upgrade`。   
* 逻辑升级:mysqldump导出数据,安装新版MySQL，加载数据到新版MySQL，运行`mysql_upgrade`。

MySQL不支持跨发布系列升级，新旧版本跨越多个发布系列时，必须依次升级。比如如果想从5.5升级到5.7，必须先升级到5.6再升级到5.7。

参考MySQL官方手册[2.11.1 Upgrading MySQL](http://dev.mysql.com/doc/refman/5.7/en/upgrading.html)

###3.4.2 PostgreSQL  
PostgreSQL的版本号由3组数字组成，比如9.5.1。其中前两个数字构成了主版本号，第3个数字代表小版本号。小版本发布通常只是Bugfix，并且从不改变内部存储格式并且总是与之前的相同主版本的发布版本兼容。

主版本发布大约1年1次，维护周期为5年，小版本升级大约2个月1次。最近的几个主版本发布时间如下 
 
	PostgreSQL 9.0: 2010-09-20
	PostgreSQL 9.1: 2011-09-12 
	PostgreSQL 9.2: 2012-09-10
	PostgreSQL 9.3: 2013-09-09
	PostgreSQL 9.4: 2014-12-18
	PostgreSQL 9.5: 2016-01-07

**升级方法**  
主版本升级(特性增强)  

* 方法1: 停机，`pg_dump`，`pg_restore`   
* 方法2: 逻辑复制（使用`londiste3`, `slony-I`之类的逻辑复制工具)   
* 方法3: `pg_upgrade`   

小版本升级(BugFix)  
替换新版本数据库软件后重启PostgreSQL服务


参考PostgreSQL官方手册[17.6. Upgrading a PostgreSQL Cluster](http://www.postgresql.org/docs/9.5/static/upgrading.html)

###3.4.3 评价   
PostgreSQL的主版本更新的周期更短，平均一年一次；而MySQL的主版本升级平均2年一次。PostgreSQL小版本升级只是Bugfix不会增加新特性；而MySQL的小版本更新会增加和修改功能；并且，PostgreSQL提供的升级工具支持跨主版本升级，MySQL不可以。因此PostgreSQL的版本升级风险更低也更加容易实施。


##3.5 流行程度  
MySQL显然更加流行，有观点认为，PostgreSQL之所远不如MySQL流行，是一些因素共同作用的结果。 
 
1. 互联网行业兴起时期（2000年前后），MySQL作为一个轻量快速易用的开源数据库正好适配的互联网的需求，因而被大量使用。  
2. 互联网巨头的示范作用进一步促进了MySQL的普及。  
3. 早期的PostgreSQL在性能和易用性不如MySQL，比如:   
	+ PostgreSQL直到8.0(2005-01-19)才推出Windows版本。  
	+ PostgreSQL 8.3(2008-02-04)之前的版本在性能和可维护上尚不如人意(比如没有HOT更新)。  
	+ PostgreSQL直到9.0(2010-09-20)才推出流复制功能。  

但PostgreSQL凭借其丰富的特性和日益提升的性能,用户量正呈现出快速上升的势头。并且在PostgreSQL接受程度较高的日本市场，PostgreSQL的用户量和MySQL相当，甚至超过。

**参考：**  

* http://db-engines.com/en/ranking/  

* http://db-engines.com/en/ranking_trend/system/Oracle;MySQL;Microsoft%20SQL%20Server;Mongodb;PostgreSQL


##3.6 用户案例
###MySQL 
MySQL在WEB类业务上非常流行，尤其在互联网行业几乎是标配。也有用于其它业务的案例。
可参考:http://www.mysql.com/customers/

###PostgreSQL
PostgreSQL在各个行业均有应用案例。国内的知名用户包括：阿里巴巴，腾讯, 平安，移动，华为, 中兴,去哪儿, 斯凯, 云游, 顺丰，高德，探探等。一些用户看中了PostgreSQL的稳定可靠，复杂查询和GIS处理能力，特别是GiS，从一些实际用户的选型和反馈来看，PostgreSQL+PostGiS被认为是目前最有优势的开源GiS数据库方案。
可参考：http://www.postgresql.org/about/users/


##3.7 资料和文档
###MySQL  
MySQL由于非常流行，国内相关技术书籍和资料非常多。但缺少较新的中文手册，目前可以找到的最新的MySQL中文手册是MySQL 5.1。

###PostgreSQL
早年PostgreSQL相关的中文技术资料和书籍匮乏，但目前已经比较丰富，并且每年都有新的中文PostgreSQL书籍诞生，PostgreSQL相关的技术交流和分享也很活跃。另外，PostgreSQL官方手册相当精良无论想入门还是深入均可受益，并且PostgreSQL中国用户会还在其官网上提供了中文版的手册。   

* http://www.postgres.cn/docs/9.3
* http://www.postgres.cn/docs/9.4
* http://www.postgres.cn/docs/9.5



#4. 架构与实现
##4.1 多线程vs多进程
MySQL是多线程模型，PostgreSQL是多进程模型。
###多线程相比多进程的优点  
* 线程的创建删除和切换成本低

###多线程相比多进程的缺点
* 代码更难理解，更容易出bug,也更难调试
* 多核CPU的利用效率不高，对NUMA架构支持不好。有测试表明在超过24个core的系统上，MySQL不能充分利用CPU的能力。

###点评
客户端到数据库的连接通常使用连接池，并且数据库的最大连接数通常会被限制在1000以内，这可以大大缓解多进程创建删除和切换成本高的问题。所以PostgreSQL的多进程模型更占优势。（需要注意的是，由于PostgreSQL的多进程模型，在Windows上的性能受到了一定的影响。）


##4.2 多引擎 vs FDW
MySQL的SQL层和存储层分离，支持多种存储引擎，例如InnoDB, MyISAM, NDB。PostgreSQL和绝大多数数据库一样是单存储引擎，但是PostgreSQL可以通过FDW支持其它的储存形式，比如csv，mysql，hadoop等。


MySQL多引擎的优点  

* 数据库厂商只需开发存储引擎部分就能得到一个全新用途的数据库，比如NDB和TokuDB。
* 用户可以根据不同场景灵活选择最合适的存储引擎，而不用改应用接口。

MySQL多引擎的缺点

* SQL层需要兼顾所有存储引擎，增加了系统的复杂度，很难做到最优    
* 不同存储引擎有不同的适用场景和限制，增加了用户选择的难度  
* 大多数用户只需要使用InnoDB，对其它存储引擎的支持反而是个累赘，甚至是个隐患。

PostgreSQL FDW的优点

* FDW是SQL标准
* FDW有自己的内部接口和内置的堆表存储不同，可以分别扩展和优化。
* FDW的内部接口更轻量，开发新的FDW更容易
* 已经支持的FDW非常丰富，参考https://wiki.postgresql.org/wiki/Fdw

PostgreSQL FDW的缺点

* PostgreSQL FDW提供的外部表的功能相对于普通的堆表不够全面。

注：MySQL也支持FDW，但目前只有mysql的FDW，不是主流。

##4.3 binlog + redo log + undo log vs WAL + MVCC
###MySQL
MySQL在SQL层通过binlog记录数据变更并基于binlog实现复制和PITR。另外在Innodb存储层有和其它数据库类似的redo log和undo log以支持事务的ACID。由于MySQL有两套日志，为了确保严格的持久性，以及保证2个日志中事务顺序的一致，每次事务提交需要刷3次盘,严重影响性能。这就是所谓的双1问题(`sync_binlog=1,innodb_flush_log_at_trx_commit=1`)

1. Innodb Prepare
2. binlog Commit
3. Innodb Commit

虽然MySQL通过Group Commit的优化措施可以在高并发时大大减少了刷盘的次数，但双1的配置对性能的影响仍然存在。所以不少生产系统并未设置双1，冒了主备数据不一致的风险。

###PostgreSQL
PostgreSQL和其它常见数据库（比如Oracle）不一样的地方在于，它只有redo log(PostgreSQL中称之为WAL)没有undo log。数据发生变更时，PostgreSQL通过记录在堆表的每个行版本的事务id，识别被更新或删除的旧数据。因为旧数据就在保存在堆表中，不需要undo log就可以支持事务的回滚。
PostgreSQL的MVCC实现方式的优点

1. 事务回滚和故障恢复很快，在没有发生磁盘故障时很少出现宕机后不能启动的情况。
2. 不会出现由于undo log空间不够而导致大事务失败的情况
3. 不用写undo log所以日志写入量少

PostgreSQL的MVCC实现方式的缺点

1. 堆表和索引容易膨胀，需要定期执行VACUUM
利用好HOT更新技术，可以减少表的膨胀，但索引的膨胀往往比表膨胀更严重。
恰当的配置auto vacuum通常可以有效的消除膨胀，但定期的表膨胀检查和处理也是不可少的。
PostgreSQL9.6和开发中的版本10，对表膨胀的处理都有重大改进。


##4.4 binlog复制 vs 流复制
MySQL的复制传输的是SQL层的binlog记录，binlog记录的是数据的逻辑变更(SQL语句或基于行的数据变更)，属于逻辑复制；PostgreSQL的复制传输的是WAL记录，WAL记录的是数据块的变更，属于物理复制。

binlog复制的优点 
 
* 支持不同版本MySQL间的复制
* 可以只复制部分数据
* 支持所有存储引擎

binlog复制的缺点

* Slave回放binlog时需要把SQL再执行一次消耗的资源比较多，并且Master端的SQL执行是多线程而Salve端的SQL回放通常是单线程，因此容易导致主从延迟。  
 MySQL 5.7通过并行复制很大程度上缓解了主从延迟的问题，但未根治，而且即使不考虑主从延迟，Slave回放的资源消耗也远大于PostgreSQL。
* binlog是逻辑复制，很难确保主从数据库的数据一致，而且一旦数据出现了不一致也不一定能立即发现。
 根据阿里的技术分享，阿里云MySQL RDS为了最大可能确保主从数据一致，采用了row格式的复制，并且阿里内部正在开发基于redo log的复制准备将来替换binlog复制。
* MySQL 5.6以前的版本不支持GTID，复制集群没有一个统一的方式识别复制位置，给集群管理带来了很多不便。
* MySQL 5.6启用GTID需要在Slave端也记录binlog(开启`log_slave_updates`选项)，增加了资源消耗。
* MySQL 5.7启用GTID不要求Slave必须开binlog，但如果不开，1主多从复制下，主备切换又不太好处理，所以还是建议开。

PostgreSQL流复制的优点

* 强数据一致
* Slave恢复消耗资源少，速度快，不容易出现主从延迟(尤其是同步复制时)
* 通过Logical Decoding也可实现逻辑复制

PostgreSQL流复制的缺点

* 目前只是提供了逻辑复制的基础设施，实际部署时需要进行定制，缺少现成的解决方案。


##4.5 数据存储
###MySQL
MySQL的数据库名直接对应于文件系统的目录名，表名直接对应于文件系统的文件名。这导致MySQL的数据库名和表名支持的字符以及是否大小写敏感都依赖于文件系统。
MySQL的表定义存储在特别的.frm文件中，DDL操作不支持事务。
MySQL的所有Innodb表数据可以存储在单个.idb文件中,也可以每个表一个.idb文件(通过参数`innodb_file_per_table`控制)，即使每个表一个.idb文件，同一个表的数据和索引都在这一个文件里。
MySQL的Innodb表的存储格式是Btree索引组织表，每个表必须有主键，如果创建表时没有指定主键，MySQL会创建一个内部主键。索引组织表的优点是按主键查询快，但数据插入时如果主键不是递增的，会导致Btree树大量分裂影响性能。

MySQL的二级索引中存储的行位置不是Innodb表中的物理位置而是Innodb表中的主键值。所以MySQL通过二级索引查找记录需要执行两次索引查找。并且如果主键太长，会过多占用二级索引的存储空间，所以有些场景下，放弃自然主键而采用额外的自增字段作为主键效果会更好。

###PostgreSQL
PostgreSQL中的数据库对应于文件系统的目录，表对应于文件系统的文件，但目录名和文件名都是PostgreSQL内部的id号，不存在非法字符和大小写的问题。
PostgreSQL的每个表的数据和每个索引都存储在单独的文件中，并且文件操过1GB时，每个GB再拆分为一个单独的文件。

PostgreSQL中存储元数据的系统表和普通表的存储格式完全相同，这使得PostgreSQL很容易扩展，并且PostgreSQL的DDL操作也支持事务。

PostgreSQL对长度大于127字节的字段值采用被称为TOAST (The Oversized-Attribute Storage Technique)的技术进行存储。即将这些大字段切分为若干个chunk存储在这个堆表对应的toast表中，每个chunk占一行，最大2000字节，原始表中仅仅存储一个指针。并且PostgreSQL可能会对长度大于127字节的数据自动进行压缩。得益于TOAST技术，PostgreSQL能够很好的处理包含大字段的表。


#5. SQL特性
MySQL早期的定位是轻量级数据库，虽然后来做了很多增强，比如事务支持，存储过程等，但和其它常见的关系数据库比起来SQL特性的支持仍比较弱，目前宽泛的SQL 99的子集。
PostgreSQL的定位是高级的对象关系数据库，从一开始对SQL标准的支持比较全面，目前支持大部分的SQL:2011特性。

关于SQL特性支持情况的对比，可以参考[http://www.sql-workbench.net/dbms_comparison.html](http://www.sql-workbench.net/dbms_comparison.html)

	                 PostgreSQL | Oracle | DB2 | SQL Server | MySQL
	支持的SQL特性       94           77      69       68        36
	不支持的SQL特性     16           33      41       42        74      
    
下面是MySQL和PostgreSQL的SQL特性支持差异的说明

##5.1 仅MySQL支持的SQL特性

MySQL支持而PostgreSQL不支持的特性有5个

* Query variables  
  不需要定义存储过程，直接在单个语句中定义变量。仅SQL Server和MySQL支持这一特性。    
  使用例：

		mysql> set @a=1;
		Query OK, 0 rows affected (0.00 sec)
		
		mysql> SELECT @a, @a:=@a+1 from tb1 limit 2;
		+------+----------+
		| @a   | @a:=@a+1 |
		+------+----------+
		|    1 |        2 |
		|    2 |        3 |
		+------+----------+
		2 rows in set (0.00 sec) 

* Clustered index  
  PostgreSQL虽然不支持集蔟索引，但提供了cluster命令能够达到类似的效果。

* ALTER a table used in a view   
   修改被视图使用的表定义而不需要DROP视图。但是这可能会导致视图失效。  

		mysql> create view v1 as select id from tb1;
		Query OK, 0 rows affected (0.01 sec)
		mysql> alter table tb1 rename to tb1_new;
		Query OK, 0 rows affected (0.00 sec)
		mysql> select * from v1;
		ERROR 1356 (HY000): View 'test.v1' references invalid table(s) or column(s) or function(s) or definer/invoker of view lack rights to use them

    其实这一项PostgreSQL也支持，但PostgreSQL不允许Drop被视图引用的列和修改列定义。
    对其它类型的表修改，视图仍然有效。

		postgres=# create view v1 as select id from tb1;
		CREATE VIEW
		postgres=# alter table tb1 rename  to tb1_new;
		ALTER TABLE
		postgres=# insert into tb1_new values(1,1);
		INSERT 0 1
		postgres=# select * from v1;
		 id 
		----
		  1
		(1 row)

	如果Drop被视图引用的列，PostgreSQL会报错并提示使用DROP ... CASCADE。

		postgres=# alter table tb1_new drop id;
		ERROR:  cannot drop table tb1_new column id because other objects depend on it
		DETAIL:  view v1 depends on table tb1_new column id
		HINT:  Use DROP ... CASCADE to drop the dependent objects too.

* Add table column at specific position  
  增加列到指定的位置而不是添加到最后，这会影响"select *"输出的列顺序。但MySQL实现方式需要拷贝表，因此修改大表的定义很耗资源。

		mysql> alter table tb1 add c2 int after id;
		Query OK, 0 rows affected (0.02 sec)
		Records: 0  Duplicates: 0  Warnings: 0

* Built-in scheduler  
 PostgreSQL的pgagent插件可以达到相同的效果，并且PostgreSQL提供了[章 45. 后台工作进程](http://www.postgres.cn/docs/9.3/bgworker.html)机制，可以比较容易的定制调度任务。


##5.2 仅PostgreSQL支持的特性

PostgreSQL支持而MySQL不支持的特性有62个，如下。

###5.2.1 Queries

* Window functions    
    SQL2003引入的特性，允许针对每一行计算分组值而整个分组只有一个值。
	使用例：计算每个人在全公司的薪水排名和在其所在部门的薪水排名

		SELECT last_name,
		       first_name,
		       department_id,
		       salary,
		       rank() over (order by salary DESC) "Overal Rank",
		       rank() over (partition by department_id ORDER by salary DESC) "Department Rank"
		FROM employees
		ORDER BY 1,2;

* Common Table Expressions   
  SQL标准中的特性。很像子查询，不同的是可以在一个查询中被使用多次，并且简化SQL的书写。
  使用例：

		WITH plist (id, name) AS (
		  SELECT id, 
		         firstname||' '||lastname
		  FROM person
		  WHERE lastname LIKE 'De%'
		)
		SELECT o.amount,
		       p.name
		FROM orders o
		  JOIN plist p ON p.id = o.person_id;

* Recursive Queries    
  Common Table Expressions的一种特殊语法，可用于查询继承数据，比如列出一名员工所有的直接和间接上级。
  使用例：计算1到100的和(递归)

		WITH RECURSIVE t(n) AS (
		    VALUES (1)
		  UNION ALL
		    SELECT n+1 FROM t WHERE n < 100
		)
		SELECT sum(n) FROM t;

	输出结果：

		sum  
		------
		 5050
		(1 row)

    更有意义的例子请参考:http://www.sql-workbench.net/comparison/recursive_queries.html

* Row constructor    
	使用例：

		SELECT * FROM ( VALUES (1,2), (2,3) ) tbx;

* Filtered aggregates   
	使用例：

		select customer_id, 
		       sum(amount) as total_amount,
		       sum(amount) filter (where amount > 10000) as large_orders_amount
		from customers
		group by customer_id;

* SELECT without a FROM clause    
	不带where条件时，MySQL是支持的。

		mysql> select 1;
		+---+
		| 1 |
		+---+
		| 1 |
		+---+
		1 row in set (0.00 sec)
		
		mysql> select 1  where 1 = 1 ;
		ERROR 1064 (42000): You have an error in your SQL syntax; check the manual that corresponds to your MySQL server version for the right syntax to use near 'where 1 = 1' at line 1

* Tuple updates    
	使用例：

		UPDATE foo SET (a,b) = (SELECT c,d FROM bar WHERE bar.f_id = foo.id);

###5.2.2 Regular Expressions
* Substring    
	基于正则表达式抽取部分字符串

* Replace    
	基于正则表达式替换字符串

###5.2.3 Constraints  
* Deferred constraints  
  定义约束在提交阶段而不是语句执行进行检查。对于外键约束，这可以使插入删除语句不必考虑执行的顺序。

* Check constraints  
	使用例：不允许薪水为负数

		create table employees
		(
		   emp_id       integer not null primary key,
		   last_name    varchar(100) not null,
		   first_name   varchar(100),
		   salary       numeric(12,2) not null check (salary >= 0)
		);

* Check constraints using custom functions   
  使用定制函数实施Check约束
	使用例：

		create function is_valid(p_to_check integer)
		  returns boolean
		as
		$$
		  select p_to_check = 42
		$$
		language sql;
		
		create table answers
		(
		   question_id      integer not null,
		   answer_value     integer not null check (is_valid (answer_value))
		);

* Exclusion constraints   
	使用例：会议室预约，不允许同一会议的预约时间出现重叠。

		create table meeting_room_reservation
		(
			roomid text,
			during tsrange,
			username text,
			EXCLUDE USING gist (roomid WITH =,during WITH &&)
		)

* Statement based constraint evaluation   
	基于语句的约束评估
	使用例：

		create table fk_test
		(
		  id          integer not null primary key,
		  parent_id   integer,
		  foreign key (parent_id) references fk_test (id)
		);
		
		insert into fk_test (id,parent_id) values (1, null);
		insert into fk_test (id,parent_id) values (2, 1);
		insert into fk_test (id,parent_id) values (3, 2);
		insert into fk_test (id,parent_id) values (4, 3);

	对以上数据，如果采用row by row的约束检查，下面的delete操作将失败，但在语句的最后评估则会成功。
		delete from fk_test 
		where id in (2,3,4);

###5.2.4 Indexing 

* Partial index   
  允许索引表的子集而不是整个表
  使用例：在所有活动项目中项目名必须唯一

		create table projects
		(
		   project_id integer not null primary key,
		   name       varchar(100) not null,
		   is_active  boolean;
		);
		
		create unique index idx_unique_active_name 
		   on projects (name)
		   where is_active

* Descending Index    
	指定索引的排序顺序。对多列分别按不同顺序排序的场景特别有用。

		postgres=# create table tb1(c1 int,c2 int);
		CREATE TABLE
		postgres=# create index idx_tb1_1 on tb1(c1 asc,c2 desc);
		CREATE INDEX
		postgres=# explain select * from tb1 order by c1 asc,c2 desc;
		                                  QUERY PLAN                                  
		------------------------------------------------------------------------------
		 Index Only Scan using idx_tb1_1 on tb1  (cost=0.15..78.06 rows=2260 width=8)
		(1 row)


* Index on expression   
   创建基于表达式或函数的索引。
   使用例：

		create index month_only 
	    	on orders (extract(month from order_date));

		select count(*) 
		from orders
		where extract(month from order_date) = 8;

	MySQL 5.7中可以使用虚拟列达到相同的效果

		ALTER TABLE orders ADD COLUMN vcmonth int AS (MONTH(order_date)) stored, ADD KEY idx_month (vcmonth);

* Index using a custom function    
	使用定制函数创建索引


###5.2.5 DML
* Writeable CTEs  
	common table expression可以使用一个或多个DML

		with old_orders as (
		   delete from orders
		   where order_date <= current_date - interval '2' year
		   returning *
		)
		insert into archived_orders
		select * 
		from old_orders;

* TRUNCATE table with FK    
   MySQL不支持TRUNCATE有外键引用的表。

		mysql> truncate  tb;
		ERROR 1701 (42000): Cannot truncate a table referenced in a foreign key constraint (`test`.`tbp`, CONSTRAINT `tbp_ibfk_1` FOREIGN KEY (`pid`) REFERENCES `test`.`tb` (`id`))

   PostgreSQL可以通过CASCADE联级TRUNCATE。

		postgres=# truncate tb;
		ERROR:  cannot truncate a table referenced in a foreign key constraint
		DETAIL:  Table "tbp" references "tb".
		HINT:  Truncate table "tbp" at the same time, or use TRUNCATE ... CASCADE.
		postgres=# truncate tb CASCADE;
		NOTICE:  truncate cascades to table "tbp"
		TRUNCATE TABLE

   另外发现，MySQL创建外键有个BUG，下面的语句表面上成功了，但实际上并没有创建FK。
		
		mysql> create table tbp(id int,pid int REFERENCES tb(id) on delete RESTRICT);
		Query OK, 0 rows affected (0.05 sec)
		
		mysql> show create table tbp;
		+-------+-----------------------------------------------------------------------------------------------------------------------+
		| Table | Create Table                                                                                                          |
		+-------+-----------------------------------------------------------------------------------------------------------------------+
		| tbp   | CREATE TABLE `tbp` (
		  `id` int(11) DEFAULT NULL,
		  `pid` int(11) DEFAULT NULL
		) ENGINE=InnoDB DEFAULT CHARSET=latin1 |
		+-------+-----------------------------------------------------------------------------------------------------------------------+
		1 row in set (0.00 sec)



* Read consistency during DML operations    
   在一个表的DML中，所有读应该读到该DML之前的值。下面的例子是交换2个列的值。

		create table foo
		(
		  id1 integer not null,
		  id2 integer not null, 
		  primary key (id1, id2)
		);
		
		insert into foo 
		  (id1, id2) 
		values 
		  (1,2);
		
		update foo 
		  set id1 = id2,
		      id2 = id1;
		
		select * 
		from foo;

	正确的返回值是2，1。其它数据库的结果都是正确的唯独MySQL返回2，2。

* Use target table in sub-queries    
	在一个DML中允许使用目标表多次。
	使用例：删除表中有重复值的行

		DELETE FROM some_table
		WHERE (a,b) IN (SELECT a,b
		                FROM some_table
		                GROUP BY a,b
		                HAVING count(*) > 1);

* SELECT .. FOR UPDATE NOWAIT    
  查询并锁住行用于将来的更新，当不能获得锁时报错而不是等待。
  
* RETURNING clause as a result set    
	使用例：

		thomas@postgres/public> delete from person where id = 42 returning *;
		---- person
		id | firstname | lastname
		---+-----------+---------
		42 | Arthur    | Dent

###5.2.6 Data Types

* User defined datatypes

	使用例：
		create type address as
		(
		  zip_code varchar(5),
		  city     varchar(100),
		  street   varchar(100)
		);
		
		create table contact
		(
		  contact_id       integer not null primary key,
		  delivery_address address,
		  postal_address   address
		);


* Domains  
	在标准类型上施加约束，长度限制的领域类型
	使用例：

		create domain positive_number 
		    as numeric(12,5) not null 
			check (value > 0);
			
		create table orders
		(
		  order_id     integer not null primary key,
		  customer_id  integer not null references customers,
		  amount       positive_number
		);


* Arrays
* IP address
* BOOLEAN
* Interval
* Range types   
  范围类型在需要使用时间段，IP地址段等的场景下，结合PostgreSQL特有的gist索引非常有用，比如在场馆预订系统中能够快速判断时间段有无冲突。

###5.2.7 DDL
* Transactional DDL    
* Functions as column default   
* Sequences    
* Non-blocking index creation    
* Cascading DROP    
   DROP被外键约束依赖的表
* DDL Triggers   
  PostgreSQL支持下列时点的触发器
  1. 在CREATE, ALTER, 或 DROP 命令执行之前
  2. 在CREATE, ALTER, 或 DROP 命令执行之后
  3. 在删除数据库对象的任意操作触发ddl_command_end事件之前

* TRUNCATE Trigger
* Custom name for PK constraint

###5.2.8 Temporary Tables
* Use a temporary twice in a single query    
	MySQL中在单个查询中使用临时表2次会报错
	
		mysql> select * from tbtmp join tbtmp b on(id);
		ERROR 1137 (HY000): Can't reopen table: 'tbtmp'

###5.2.9 Programming
* Table functions    
	PostgreSQL中函数的返回值可以是表
    使用例：生成序列的函数

		postgres=# select generate_series(1,3);
		 generate_series 
		-----------------
		               1
		               2
		               3
		(3 rows)


* Custom aggregates    
	使用SQL自定义聚集函数

* Function overloading    
	创建多个函数名相同但参数不同的函数。

* User defined operators    
	创建用户自定义操作符（主要为自定义数据类型）。

* Statement level triggers    
   每个语句触发的触发器。MySQL只支持记录级别的触发器。

* RETURNING clause in a programming language    
  RETURNING子句可以返回DML的结果

		postgres=# delete from tb where c1 >1 returning *;
		 c1 | c2 
		----+----
		  2 |  2
		  2 |  3
		(2 rows)
		
		DELETE 2

* Dynamic SQL in functions    
	在函数中使用动态SQL
   使用例：

		EXECUTE 'UPDATE tbl SET '
		        || quote_ident(colname)
		        || ' = '
		        || quote_literal(newvalue)
		        || ' WHERE key = '
		        || quote_literal(keyvalue);

* Dynamic SQL in triggers    
  在触发器函数中使用动态SQL

* Delete triggers fired by cascading deletes    
  由于ON DELETE CASCADE的外键导致的级联删除也触发删除触发器

###5.2.10 Views
* Triggers on views    
	在视图上创建触发器

* Views with derived tables    
	视图中包含派生表。MySQL中出现这种情况会报错
	
		mysql> create view v_foo 
		    -> as 
		    -> select f.*, 
		    ->        b.cnt 
		    -> from foo f 
		    ->   join ( 
		    ->      select fid, count(*) as cnt 
		    ->      from bar 
		    ->      group by fid 
		    ->   ) b on b.fid = foo.id;
		ERROR 1349 (HY000): View's SELECT contains a subquery in the FROM clause

###5.2.11 JOINs and Operators
* FULL OUTER JOIN
* LATERAL JOIN
* INTERSECT
* EXCEPT
* ORDER BY ... NULLS LAST
* BETWEEN SYMMETRIC    
   允许BETWEEN的上下边界是任意顺序

		select *
		from foo
		where id between symmetric 42 and 24;

* OVERLAPS
	检查时间间隔的重叠

		select (date '2014-01-01', date '2014-09-01') 
				overlaps (date '2014-04-01', date '2014-05-01');

###5.2.12 Other
* Schemas    
   MySQL不支持Schema，但实际上MySQL的Database相当于其它数据库的Schema。

###5.2.13 NoSQL Features
* Key/Value storage    
  PostgreSQL的hstore数据类型即KV类型。

###5.2.14 Security
* User groups / Roles
* Row level security
* Grant on column level


#6. 性能相关特性
##6.1 索引
* MySQL  
索引类型支持Btree，hash，空间索引，全文检索。自动hash索引(一些场合性能不升反降)。Change Buffering优化索引更新。

* PostgreSQL   
索引类型支持btree,hash,gist,sp-gist,gin，brin。已实现的索引算法包括R树，四叉树，基数树等。索引是可扩展的，支持部分索引，支持降序索引。

##6.2 SQL优化
* MySQL    
	1.explain不易理解，trace信息过细。   
	2.统计信息匮乏(只有总记录数和索引列的唯一值数,尚未GA的MySQL8.0支持直方图)   
	3.只支持nest loop join   
	4.复杂查询性能不佳    

* PostgreSQL    
	1.explain易于理解(树状显示，cost，实际执行时间，buffer和IO使用)   
	2.统计信息丰富(直方图分布统计，频繁值统计，顺序性等)   
	3.支持nest loop,merged sort和hash join   
	4.复杂查询表现优异   

##6.3 查询缓存
* MySQL    
自带查询缓存，依赖的表更新时自动失效。每次读查询缓存都需要获取锁，很多场景下反而拖累了性能。适用场景有限，多建议禁用。

* PostgreSQL    
有查询缓存插件，使用案例似乎不多见。

##6.4 线程池/连接池
* MySQL   
企业版支持线程池，社区版不支持。但Percona Server 5.6以上也支持线程池,由于可以做到语句级的连接复用效果相当不错。

*  PostgreSQL   
有独立的轻量级连接池pgbouncer，已有大量用于生产的案例。



#7. 参考

* [MySQL & PostgreSQL choice](http://blog.163.com/digoal@126/blog/static/1638770402015623104342195/)
* [MySQL vs PostgreSQL](http://www.wikivs.com/wiki/MySQL_vs_PostgreSQL#IO_Device_Scalability)
* [http://www.sql-workbench.net/dbms_comparison.html](http://www.sql-workbench.net/dbms_comparison.html)
* [PostgreSQL 与 MySQL 相比，优势何在？](http://www.zhihu.com/question/20010554)
* [PostgreSQL与MySQL比较](http://bbs.chinaunix.net/thread-1688208-1-1.html)
* [从源码的角度对比Postgres与MySQL](http://blog.sina.com.cn/s/blog_742eb90201010yul.html)
* [MySql vs PostGreSql vs Docker](http://glennengstrand.info/blog/?p=393)
* [PgSQL · 功能分析 · PostGIS 在 O2O应用中的优势](https://yq.aliyun.com/articles/50922)

