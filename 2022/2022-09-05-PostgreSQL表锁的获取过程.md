## 概述

在高并发访问叠加大量表和索引的数据库中，有时会产生过于频繁的加锁解锁导致性能问题。
参考:https://dba.stackexchange.com/questions/276297/postgresql-lwlock-lock-manager-issue


## 获取锁的处理流程
关于PG锁的详细介绍，相关资料也比较多了，见附录。
这里主要分析`LockAcquireExtended()`代码中获取锁时主要的处理过程

1. 检查本连接之前是否获得过相同的锁，如果已经获得过直接返回
   每个进程已经获得过的每个锁信息保存在LOCALLOCK对象，并缓存在进程私有的LockMethodLocalHash中。
   LockMethodLocalHash的大小为16，当一个会话获取的锁过多时，这里hash查找可能消耗一定时间。
   LOCALLOCK有个lockOwners成员，记录owner成员列表，owner为NULL代表会话，非空代表事务。在使用子事务的场景，可能lockOwners可能有多个成员。

```
	/*
	 * Attempt to take lock via fast path, if eligible.  But if we remember
	 * having filled up the fast path array, we don't attempt to make any
	 * further use of it until we release some locks.  It's possible that some
	 * other backend has transferred some of those locks to the shared hash
	 * table, leaving space free, but it's not worth acquiring the LWLock just
	 * to check.  It's also possible that we're acquiring a second or third
	 * lock type on a relation we have already locked using the fast-path, but
	 * for now we don't worry about that case either.
	 */
	if (EligibleForRelationFastPath(locktag, lockmode) &&
		FastPathLocalUseCount < FP_LOCK_SLOTS_PER_BACKEND)
	{
		uint32		fasthashcode = FastPathStrongLockHashPartition(hashcode);
		bool		acquired;

		/*
		 * LWLockAcquire acts as a memory sequencing point, so it's safe to
		 * assume that any strong locker whose increment to
		 * FastPathStrongRelationLocks->counts becomes visible after we test
		 * it has yet to begin to transfer fast-path locks.
		 */
		LWLockAcquire(&MyProc->backendLock, LW_EXCLUSIVE);
		if (FastPathStrongRelationLocks->count[fasthashcode] != 0)
			acquired = false;
		else
			acquired = FastPathGrantRelationLock(locktag->locktag_field2,
												 lockmode);
		LWLockRelease(&MyProc->backendLock);
		if (acquired)
		{
			/*
			 * The locallock might contain stale pointers to some old shared
			 * objects; we MUST reset these to null before considering the
			 * lock to be acquired via fast-path.
			 */
			locallock->lock = NULL;
			locallock->proclock = NULL;
			GrantLockLocal(locallock, owner);
			return LOCKACQUIRE_OK;
		}
	}
```
2. 尝试通过fash path获取锁,如果成功直接返回
   常规的方式，需要从共享内存获取锁，频繁访问，性能消耗较大。
   因此PG提供了一种优化的方式，满足以下条件时，只需从连接的私有空间申请锁，这种方式称为fash path，通过fash path获取的锁又称为弱锁。
   a) 常规表锁
   b) 锁模式 < ShareUpdateExclusiveLock (这些锁互相不阻塞)
   c) 进程的fash path槽还有空闲空间(每个进程16个fast path槽)
   d) 没有其他后端再相同对象上已经获取 > ShareUpdateExclusiveLock的锁

fash path信息记录在每个连接的MyProc结构体里。
```
struct PGPROC
{
...
	/* Lock manager data, recording fast-path locks taken by this backend. */
	uint64		fpLockBits;		/* lock modes held for each fast-path slot */
	Oid			fpRelId[FP_LOCK_SLOTS_PER_BACKEND]; /* slots for rel oids *
```

   为了检查有没有其他后端再相同对象上已经获取 > ShareUpdateExclusiveLock的锁（强锁），
   使用共享内存中的FastPathStrongRelationLocks->count[fasthashcode]进行计数，当计算值为0时，表示没有后端获取该对象上的强锁。
   fasthashcode的最大范围是1024，当系统中被持有强锁的对象很多时，由于hash冲突，fash path也难以正常发挥作用。

相关代码如下(`LockAcquireExtended()`)：
```
	if (EligibleForRelationFastPath(locktag, lockmode) &&
		FastPathLocalUseCount < FP_LOCK_SLOTS_PER_BACKEND)
	{
		uint32		fasthashcode = FastPathStrongLockHashPartition(hashcode);
		bool		acquired;

		/*
		 * LWLockAcquire acts as a memory sequencing point, so it's safe to
		 * assume that any strong locker whose increment to
		 * FastPathStrongRelationLocks->counts becomes visible after we test
		 * it has yet to begin to transfer fast-path locks.
		 */
		LWLockAcquire(&MyProc->backendLock, LW_EXCLUSIVE);// proc LW锁,每个后端1个(PG 13以后改名为LockFastPath)
		if (FastPathStrongRelationLocks->count[fasthashcode] != 0)
			acquired = false;
		else
			acquired = FastPathGrantRelationLock(locktag->locktag_field2,
												 lockmode);
		LWLockRelease(&MyProc->backendLock);
		if (acquired)
		{
			/*
			 * The locallock might contain stale pointers to some old shared
			 * objects; we MUST reset these to null before considering the
			 * lock to be acquired via fast-path.
			 */
			locallock->lock = NULL;
			locallock->proclock = NULL;
			GrantLockLocal(locallock, owner);
			return LOCKACQUIRE_OK;
		}
	}
```

3. 如果锁模式 > ShareUpdateExclusiveLock，将系统中所有进程在该对象已获得的弱锁转换成共享内存中强锁

```
	/*
	 * If this lock could potentially have been taken via the fast-path by
	 * some other backend, we must (temporarily) disable further use of the
	 * fast-path for this lock tag, and migrate any locks already taken via
	 * this method to the main lock table.
	 */
	if (ConflictsWithRelationFastPath(locktag, lockmode))
	{
		uint32		fasthashcode = FastPathStrongLockHashPartition(hashcode);

		BeginStrongLockAcquire(locallock, fasthashcode); //FastPathStrongRelationLocks->count[fasthashcode]++ 阻止其他后端以fash path方式获取弱锁
		if (!FastPathTransferRelationLocks(lockMethodTable, locktag,
										   hashcode))
		{
			AbortStrongLockAcquire();
			if (locallock->nLocks == 0)
				RemoveLocalLock(locallock);
			if (locallockp)
				*locallockp = NULL;
			if (reportMemoryError)
				ereport(ERROR,
						(errcode(ERRCODE_OUT_OF_MEMORY),
						 errmsg("out of shared memory"),
						 errhint("You might need to increase max_locks_per_transaction.")));
			else
				return LOCKACQUIRE_NOT_AVAIL;
		}
	}
```

4. 获取lock_manager LW锁（PG 13以后为LockManager）

   lock_manager的切片数是16，所以锁对象很多时，很容易不同锁对象对应到同一个锁切片，加重对lock_manager锁的等待。
```
	/*
	 * We didn't find the lock in our LOCALLOCK table, and we didn't manage to
	 * take it via the fast-path, either, so we've got to mess with the shared
	 * lock table.
	 */
	partitionLock = LockHashPartitionLock(hashcode);

	LWLockAcquire(partitionLock, LW_EXCLUSIVE);
```
5. 从共享内存的LockMethodLockHash中获取锁对象（lock和proclock），并检查是否冲突
   先检查和等待队列中的锁模式是否冲突，再检查和已持有锁的其他后端是否冲突。
   如果不冲突，在locallock添加锁授权，否则进入等待队列。

```
	proclock = SetupLockInTable(lockMethodTable, MyProc, locktag,
								hashcode, lockmode);
...
	if (lockMethodTable->conflictTab[lockmode] & lock->waitMask)
		status = STATUS_FOUND;
	else
		status = LockCheckConflicts(lockMethodTable, lockmode,
									lock, proclock);

	if (status == STATUS_OK)
	{
		/* No conflict with held or previously requested locks */
		GrantLock(lock, proclock, lockmode);
		GrantLockLocal(locallock, owner);
	}
	else
	{
...
		/*
		 * Sleep till someone wakes me up.
		 */

		TRACE_POSTGRESQL_LOCK_WAIT_START(locktag->locktag_field1,
										 locktag->locktag_field2,
										 locktag->locktag_field3,
										 locktag->locktag_field4,
										 locktag->locktag_type,
										 lockmode);

		WaitOnLock(locallock, owner);//内部在进入等待前会释放partitionLock，唤醒后重新获得partitionLock
```

6. WaitOnLock如果长时间获取不到锁，触发死锁检测

死锁检测时，要获取所有锁切片，在LockManager已经很严重的情况下，这可能会使问题更加严重。

调用关系如下
```
WaitOnLock
 ->ProcSleep
   ->CheckDeadLock
```

```
/*
 * CheckDeadLock
 *
 * We only get to this routine, if DEADLOCK_TIMEOUT fired while waiting for a
 * lock to be released by some other process.  Check if there's a deadlock; if
 * not, just return.  (But signal ProcSleep to log a message, if
 * log_lock_waits is true.)  If we have a real deadlock, remove ourselves from
 * the lock's wait queue and signal an error to ProcSleep.
 */
static void
CheckDeadLock(void)
{
	int			i;

	/*
	 * Acquire exclusive lock on the entire shared lock data structures. Must
	 * grab LWLocks in partition-number order to avoid LWLock deadlock.
	 *
	 * Note that the deadlock check interrupt had better not be enabled
	 * anywhere that this process itself holds lock partition locks, else this
	 * will wait forever.  Also note that LWLockAcquire creates a critical
	 * section, so that this routine cannot be interrupted by cancel/die
	 * interrupts.
	 */
	for (i = 0; i < NUM_LOCK_PARTITIONS; i++)
		LWLockAcquire(LockHashPartitionLockByIndex(i), LW_EXCLUSIVE);
...
```

7. 释放之前获取的lock_manager LW锁
```
	LWLockRelease(partitionLock);
```

## 验证

由于每个后端的fast path槽只有16个，当一个事务中需要访问的关系很多时，容易升级成强锁。
大量关系叠加高并发场景，可能带来明显的性能下降。用下面的测试用例在PG15上验证一下

创建有1000个分区的分区表
```
create table part(
id int,
c1 int
) partition by list(c1);



select
'create table part_' || id || ' partition OF part FOR VALUES IN(' || id || ');'
from generate_series(1,1000) id  \gexec

create index on part(id);
```

通过pgbench 执行以下SQL
```
pgbench -n -c 32 -j 32 -T 10 -f t.sql -M prepared

```

t.sql的内容为以下不带分区键的查询
```
select * from part where id=1;
```

pgbench的tps为118,并且 执行pgbench过程中，经常会见到wait_event为LockManager的会话。
将fast path的槽只有16个，扩大到1024个，再测，tps提升到136。

```
#define LOG2_NUM_LOCK_PARTITIONS 10 //4改成10
```

这个测试中，并发数只有32，如果调高并发，影响会更明显。

## 附录：参考资料
1. [PostgreSQL中的锁](https://www.modb.pro/doc/45549)
2. [揭秘 PostgreSQL 中的 Fast Path Locking](https://my.oschina.net/postgresqlchina/blog/5154753)
3. src/backend/storage/lmgr/README
