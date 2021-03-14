# PostgreSQL中的full_page_writes的理解

## 1. full\_page_writes的作用

PostgreSQL中的full\_page_writes参数用来防止部分页面写入导致崩溃后无法恢复的问题。手册中的相关描述如下：

http://postgres.cn/docs/9.3/runtime-config-wal.html#GUC-FULL-PAGE-WRITES   

**full\_page_writes (boolean)**   
打开这个选项的时候，PostgreSQL服务器在检查点之后对页面的第一次写入时将整个页面写到 WAL 里面。 这么做是因为在操作系统崩溃过程中可能只有部分页面写入磁盘， 从而导致在同一个页面中包含新旧数据的混合。在崩溃后的恢复期间， 由于在WAL里面存储的行变化信息不够完整，因此无法完全恢复该页。 把完整的页面影像保存下来就可以保证正确存储页面， 代价是增加了写入WAL的数据量。因为WAL重放总是从一个检查点开始的， 所以在检查点后每个页面第一次改变的时候做WAL备份就足够了。 因此，一个减小全页面写开销的方法是增加检查点的间隔参数值。

## 2. 为什么崩溃后无法恢复部分写入的页面
为了理解这个问题，先看看在不考虑部分写入时PostgreSQL的处理逻辑。可以简单概括如下：

1. 对数据页面的修改操作会引起页面中数据的变化。
2. 修改操作以XLOG记录的形式被记录到WAL中。
3. 页面中保存最后一次修改该页面的XLOG记录插入到WAL后的下一个字节位置(PageHeaderData.pd_lsn)。
4. 必须在最后一次修改该页面的XLOG记录已经刷入磁盘后，数据页面才能刷盘。
5. 恢复时，跳过数据页面中记录的pd_lsn位置之前的XLOG

   如果将修改操作记为Op1，Op2 ...，将数据页面的状态分别记为S1,S2和S3 ...，则如下所示：

    S1 ------> S2 ------> S3 ------> ...
        +Op1       +Op2        ...

当某个数据页面处于S1状态时，这个页面从Op1开始REDO；当数据页面处于S2状态时，从Op2开始REDO；当数据页面处于S3状态时，不需要恢复。

然而，在部分写入时，页面将不再是上面的任何一个状态，而是新旧混合的不一致的状态。如果pd\_lsn存的是新值，那么根本就不进行恢复；如果是旧值，由于恢复操作本来是要基于修改前的状态的，在中间状态上执行未必能成功，即使恢复涉及的数据部分恢复了也不能纠正页面其它地方的不一致。为了解决这个问题，PostgreSQL引入了full_page_writes，checkpoint后的第一次页面修改将完全的页内容记录到WAL，之后从上次的checkpoint点开始恢复时，先取得这个完成的页面内容然后再在其上重放后续的修改操作。

## 3. 避免部分写入
full_page_writes会带来很大的IO开销，所以条件许可的话可以使用支持原子块写入的存储设备或文件系统（比如ZFS）避免部分写入。

## 4. 其它数据库的处理
MySQL中有类似的防止部分写入的机制，叫innodb_doublewrite。原理类似，但实现稍有不同，innodb_doublewrite生效时，在写真正的数据页前，把数据页写到doublewrite buffer中，doublewrite buffer写完并刷新后才往真正的数据页写入数据。

可参考:   
http://dev.mysql.com/doc/refman/5.6/en/glossary.html#glos_doublewrite_buffer


## 5. 参考
可以参考某个XLOG的恢复代码，比如heap_xlog_insert()。

src/backend/access/heap/heapam.c

    static void
    heap_xlog_insert(XLogRecPtr lsn, XLogRecord *record)
    {
    	xl_heap_insert *xlrec = (xl_heap_insert *) XLogRecGetData(record);
    	Buffer		buffer;
    	Page		page;
    	OffsetNumber offnum;
    	struct
    	{
    		HeapTupleHeaderData hdr;
    		char		data[MaxHeapTupleSize];
    	}			tbuf;
    	HeapTupleHeader htup;
    	xl_heap_header xlhdr;
    	uint32		newlen;
    	Size		freespace;
    	BlockNumber blkno;
    
    	blkno = ItemPointerGetBlockNumber(&(xlrec->target.tid));
    
    	/*
    	 * The visibility map may need to be fixed even if the heap page is
    	 * already up-to-date.
    	 */
    	if (xlrec->flags & XLOG_HEAP_ALL_VISIBLE_CLEARED)
    	{
    		Relation	reln = CreateFakeRelcacheEntry(xlrec->target.node);
    		Buffer		vmbuffer = InvalidBuffer;
    
    		visibilitymap_pin(reln, blkno, &vmbuffer);
    		visibilitymap_clear(reln, blkno, vmbuffer);
    		ReleaseBuffer(vmbuffer);
    		FreeFakeRelcacheEntry(reln);
    	}
    
    	/* If we have a full-page image, restore it and we're done */
    	if (record->xl_info & XLR_BKP_BLOCK(0))
    	{
    		(void) RestoreBackupBlock(lsn, record, 0, false, false);
    		return;
    	}
    
    	if (record->xl_info & XLOG_HEAP_INIT_PAGE)
    	{
    		buffer = XLogReadBuffer(xlrec->target.node, blkno, true);
    		Assert(BufferIsValid(buffer));
    		page = (Page) BufferGetPage(buffer);
    
    		PageInit(page, BufferGetPageSize(buffer), 0);
    	}
    	else
    	{
    		buffer = XLogReadBuffer(xlrec->target.node, blkno, false);
    		if (!BufferIsValid(buffer))
    			return;
    		page = (Page) BufferGetPage(buffer);
    
    		if (lsn <= PageGetLSN(page))	/* changes are applied */
    		{
    			UnlockReleaseBuffer(buffer);
    			return;
    		}
    	}
    
    	offnum = ItemPointerGetOffsetNumber(&(xlrec->target.tid));
    	if (PageGetMaxOffsetNumber(page) + 1 < offnum)
    		elog(PANIC, "heap_insert_redo: invalid max offset number");
    
    	newlen = record->xl_len - SizeOfHeapInsert - SizeOfHeapHeader;
    	Assert(newlen <= MaxHeapTupleSize);
    	memcpy((char *) &xlhdr,
    		   (char *) xlrec + SizeOfHeapInsert,
    		   SizeOfHeapHeader);
    	htup = &tbuf.hdr;
    	MemSet((char *) htup, 0, sizeof(HeapTupleHeaderData));
    	/* PG73FORMAT: get bitmap [+ padding] [+ oid] + data */
    	memcpy((char *) htup + offsetof(HeapTupleHeaderData, t_bits),
    		   (char *) xlrec + SizeOfHeapInsert + SizeOfHeapHeader,
    		   newlen);
    	newlen += offsetof(HeapTupleHeaderData, t_bits);
    	htup->t_infomask2 = xlhdr.t_infomask2;
    	htup->t_infomask = xlhdr.t_infomask;
    	htup->t_hoff = xlhdr.t_hoff;
    	HeapTupleHeaderSetXmin(htup, record->xl_xid);
    	HeapTupleHeaderSetCmin(htup, FirstCommandId);
    	htup->t_ctid = xlrec->target.tid;
    
    	offnum = PageAddItem(page, (Item) htup, newlen, offnum, true, true);
    	if (offnum == InvalidOffsetNumber)
    		elog(PANIC, "heap_insert_redo: failed to add tuple");
    
    	freespace = PageGetHeapFreeSpace(page);		/* needed to update FSM below */
    
    	PageSetLSN(page, lsn);
    
    	if (xlrec->flags & XLOG_HEAP_ALL_VISIBLE_CLEARED)
    		PageClearAllVisible(page);
    
    	MarkBufferDirty(buffer);
    	UnlockReleaseBuffer(buffer);
    
    	/*
    	 * If the page is running low on free space, update the FSM as well.
    	 * Arbitrarily, our definition of "low" is less than 20%. We can't do much
    	 * better than that without knowing the fill-factor for the table.
    	 *
    	 * XXX: We don't get here if the page was restored from full page image.
    	 * We don't bother to update the FSM in that case, it doesn't need to be
    	 * totally accurate anyway.
    	 */
    	if (freespace < BLCKSZ / 5)
    		XLogRecordPageWithFreeSpace(xlrec->target.node, blkno, freespace);
    }
    


