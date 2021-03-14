# 修改PostgreSQL字段长度导致cached plan must not change result type错误

## 问题

有业务反馈在修改一个表字段长度后，Java应用不停的报下面的错误，但是越往后错误越少，过了15分钟错误就没有再发生。

    ### Error querying database.  Cause: org.postgresql.util.PSQLException: ERROR: cached plan must not change result type


## 原因

调查判断原因是修改字段长度导致执行计划缓存失效，继续使用之前的预编译语句执行会失败。

很多人遇到过类似错误，比如：
- https://blog.csdn.net/qq_27791709/article/details/81198571

但是，有两个疑问没有解释清楚。
1. 以前业务也改过字段长度，但为什么没有触发这个错误?
2. 这个错误能否自愈?


下面是进一步的分析

PostgreSQL中抛出此异常的代码如下:

    static List *
    RevalidateCachedQuery(CachedPlanSource *plansource,
                          QueryEnvironment *queryEnv)
    {
            if (plansource->fixed_result)
                ereport(ERROR,
                        (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                         errmsg("cached plan must not change result type")));
    ...
    }

pgjdbc代码里有对该异常的判断，发生异常后，后续的执行会重新预编译，不会继续使用已经失效的预编译语句。这说明pgjdbc对这个错误有容错或自愈能力。

      protected boolean willHealViaReparse(SQLException e) {
    ...
        // "cached plan must not change result type"
        String routine = pe.getServerErrorMessage().getRoutine();
        return "RevalidateCachedQuery".equals(routine) // 9.2+
            || "RevalidateCachedPlan".equals(routine); // <= 9.1
      }

### 发生条件

经验证，使用Java应用时本故障的发生条件如下:
1. 使用非自动提交模式
2. 使用prepareStatement执行相同SQL 5次以上
3. 修改表字段长度
4. 表字段长度修改后第一次使用prepareStatement执行相同SQL

## 测试验证

以下代码模拟Java连接多次出池->执行->入池，中途修改字段长度。可以复现本问题

			 Connection conn = DriverManager.getConnection(...);   
		     conn.setAutoCommit(false); //自动提交模式下，不会出错，pgjdbc内部会处理掉
		     String sql = "select c1 from tb1 where id=1";   
		     PreparedStatement prest =conn.prepareStatement(sql);   
		     
		     for(int i=0;i<5;i++)
		     {
		    	 System.out.println("i: " + i);
		    	 prest =conn.prepareStatement(sql);
		    	 ResultSet rs = prest.executeQuery();
		    	 prest.close();
		    	 conn.commit();
		     }
		     
		     //在这里设置断点，手动修改字段长度: alter table tb1 alter c1 type varchar(118);
		     
		     for(int i=5;i<10;i++)
		     {
		    	 System.out.println("i: " + i);
		    	 try {
		    	 prest =conn.prepareStatement(sql);
		    	 ResultSet rs = prest.executeQuery();
		    	 prest.close();
		    	 conn.commit();
		    	 } catch (SQLException e) {
		 			System.out.println(e.getMessage());
		 			conn.rollback();
		 		}
		     }
		    conn.close(); 

测试程序执行结果如下:

    i: 0
    i: 1
    i: 2
    i: 3
    i: 4
    i: 5
    ERROR: cached plan must not change result type
    i: 6
    i: 7
    i: 8
    i: 9

## 回避

1. 在不影响业务逻辑的前提下，尽量使用自动提交模式
2. 修改表字段长度后重启应用，或者在业务发生该SQL错误后重试(等每个Jboss缓存的连接都抛出一次错误后会自动恢复)
