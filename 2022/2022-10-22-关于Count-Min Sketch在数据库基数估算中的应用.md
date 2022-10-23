## 背景
SQL优化器在选择最优的执行计划时，需要评估算子输入输出的行数，也就是进行基数估算，基数估算的依据是统计信息。
常见的统计信息包括：记录数，唯一值数，null值比例，min/max，字段宽度，MVC,直方图等。
但是Tidb还使用了Count-Min Sketch（CMSketch）技术进行等值条件的基数估算。那么CMSketch是何物？

## 原理

Count-min Sketch算法是一个可以用来计数的算法，在数据大小非常大时，一种高效的计数算法，通过牺牲准确性提高的效率。

CM-Sketch 的内部数据结构是一个二维数组计数器，宽度 w，深度 d，和d个两两独立的哈希函数（相当于d个桶大小为w的hash表）。

更新的时候，用这些哈希函数算出 d 个不同的哈希值，然后在对应的行和列的位置上加上计数值。
查询某个值出现频次的时候，用这些哈希函数算出对应的d个计数器位置，再取这些计数值中的最小值作为输出。

### 特征
1. 更新和点查询的时间复杂度都是O(d)
2. 估算值只会比实际值大不会小
3. 需要满足$1-\delta$的概率下，误差小于等于$\varepsilon n$(n为所有值出现次数之和)，则w和d按如下设置。
$$
w=\left\lceil\frac{e}{\varepsilon}\right\rceil,
d=\left\lceil\ln \frac{1}{\delta}\right\rceil
$$

	即CM-Sketch的理论估算误差是$\frac{e}{w}n$。

### 参考
1. [Count-Min Sketch论文](http://dimacs.rutgers.edu/~graham/pubs/papers/cmencyc.pdf)
2. [知乎：Count-min Sketch 算法](https://zhuanlan.zhihu.com/p/369981005)
3. [知乎：Count-Min Sketch](https://zhuanlan.zhihu.com/p/84688298)
4. [CSDN：BloomFilter, Count-Min Sketch算法](https://blog.csdn.net/bitcarmanlee/article/details/104740264)


## 改进的算法Count-Mean-Min Sketch
当数据中的唯一值很少，甚至少于w时，hash冲突也少，估算值会很准确。但是，这种场景可以直接把每个唯一值的计数都记录下来，并不能充分体现CMSketch时间和空间效率上的优势。

但是，当数据中的唯一值很多，远大于w时，误差又非常大，特别对于低频的元素。
因此有人提出 Count-Mean-Min Sketch算法，消除一部分误差。

参考：https://blog.csdn.net/bitcarmanlee/article/details/104740264
```
6.Count-Mean-Min Sketch
Count-Min Sketch算法对于低频的元素，结果不太准确，主要是因为hash冲突比较严重，产生了噪音，例如当m=20时，有1000个数hash到这个20桶，平均每个桶会收到50个数，这50个数的频率重叠在一块了。Count-Mean-Min Sketch 算法做了如下改进：
1.来了一个查询，按照 Count-Min Sketch的正常流程，取出它的d个sketch
2.对于每个hash函数，估算出一个噪音，噪音等于该行所有整数(除了被查询的这个元素)的平均值
3.用该行的sketch 减去该行的噪音，作为真正的sketch
4.返回d个sketch的中位数

class CountMeanMinSketch {
    // initialization and addition procedures as in CountMinSketch
    // n is total number of added elements
    long estimateFrequency(value) {
        long e[] = new long[d]
        for(i = 0; i < d; i++) {
            sketchCounter = estimators[i][ hash(value, i) ]
            noiseEstimation = (n - sketchCounter) / (m - 1)
            e[i] = sketchCounter – noiseEstimator
        }
        return median(e)
    }
}
Count-Mean-Min Sketch算法能够显著的改善在长尾数据上的精确度。
```

这里有个问题，假设所有元素是均匀分布的，那么每个桶的计数值是相同的，也就是上面的`sketchCounter – noiseEstimator`值为0，即所有元素的估算值相加为0，看上去不太合理。

如果我们知道唯一值的数量，可以再改进一下，算出每个桶平均存储多少元素，记为p（最小为1）。那么上面noiseEstimation的计算可以考虑改为

```
noiseEstimation =((p - 1) / p) * (n - sketchCounter) / (m - 1) 
```

## 类似的算法Count Sketch

Count Sketch中除了二维数组,还增加了一组独立hash函数g用于纠正偏差，hash函数g的结果只有1和-1两个值。
增加一个元素i，计数器中增加的值为 g(i)，查询元素j的时候，将记录的计数值乘以g(j)。
最后对通过d个hash桶获的数据求平均值。以下是实现的伪代码
https://blog.csdn.net/dm_ustc/article/details/45972811
```
//Counts[1…t][1…k]:计数数组
//hash function h:[n]->[k]:共t个,h_1到h_t
//hash function g:[n]->{1,-1}:共t个,g_1到g_t
void Process(vector<int>vec){//处理整个数据流
	for(int i=0;i<vec.size();i++){
		for(int j=0;j<t;j++){
			C[j][h_j(vec[i])]=C[j][h_j(vec[i])] + g_j(vec[i]);
		}
	}
}
int query(int a){//查询a元素出现次数
	return median(g_j(a)*C[j][h_j(a)]);//for j=1 to t
}
```

查询元素j的时候，不等于j但和j的hash值冲突被累加到同一计数器中值，通过求平均值，在概率上会互相抵消。
参考下面的示例：
https://stackoverflow.com/questions/6811351/explaining-the-count-sketch-algorithm

假设增加以下元素,并且它们都映射到同一个hash桶
```
a: 3, b: 2, c: 1
```
得到的计数器值如下：
```
 h  |
abc |  X = counter
----+--------------
+++ | +3 +2 +1 =  6
++- | +3 +2 -1 =  4
+-- | +3 -2 -1 =  0
+-+ | +3 -2 +1 =  2
--+ | -3 -2 +1 = -4
--- | -3 -2 -1 = -6
-+- | -3 +2 -1 = -2
-++ | -3 +2 +1 =  0
```

计算各元素数
```
            (6 + 4 + 0 + 2) - (-4 + -6 + -2 + 0)
E[h(a) X] = ------------------------------------ = 24/8 = 3
                             8

            (6 + 4 + -2 + 0) - (0 + 2 + -4 + -6)
E[h(b) X] = ------------------------------------ = 16/8 = 2
                             8

            (6 + 2 + -4 + 0) - (4 + 0 + -6 + -2)
E[h(c) X] = ------------------------------------ =  8/8 = 1 .
                             8
```
本示例中，使用了8组计数器（和hash函数），覆盖abc 3个元素的所有组合，最后还原出准确的计算值。
实际应用中不可能使用这么多组计数器，不难看出，如果没有这么多组计数器组合，误差也会非常大。

不过，Count Sketch理论上的误差小于Count-Min Sketch。

### 参考
- [CSDN:数据流基本问题--基于sketch进行Frequency Estimation](https://blog.csdn.net/dm_ustc/article/details/45972811)
- [Finding Frequent Items in Data Streams](https://www.cs.princeton.edu/courses/archive/spring04/cos598B/bib/CharikarCF.pdf)
- [Explaining The Count Sketch Algorithm](https://stackoverflow.com/questions/6811351/explaining-the-count-sketch-algorithm)



## SMSketch在数据库中的应用
目前TIDB中使用了SMSketch结合TopN用于等值条件的基数估算，估算方法如下：

1. TopN和SMSketch都排除采样中只出现1次的元素
2. 根据采样数据中的唯一值数和参数numTop(默认20)，结合数据分布计算确定实际TopN的大小【代码参考1】
	- 实际TopN的大小最大不超过sampleNDV，也不超过numTop*2
	- 如果已超过numTop，实际TopN中最末尾的元素数必须大于numTop-1元素数的2/3
3. 如果实际TopN中元素的总记录数超过采样记录数的10%才启用TopN
4. TopN以外的采样数据记录到SMSketch
5. TopN和SMSketch以外的元素基于唯一值数进行估算【代码参考2】


但是，由于估算误差较大，在 v5.3.0 及之后的版本中，默认已经禁用了SMSketch。 
参考https://docs.pingcap.com/zh/tidb/stable/statistics#count-min-sketch

作为替代SMSketch的改进，TiDB在直方图上的记录唯一值数。
```
直方图的桶中记录了各自的不同值的个数，且直方图不包含 Top-N 中出现的值
```
这个方法显然效果要更好。
1. 单个柱的区间更小，统计数据更精细
2. 直方图按字段值排序，相比随机分布的hash值，字段值的大小通常有业务含义，相邻的元素更容易表现出相似的频率特征。所以直方图一定程度上可以代表到没有被采样到的数据。


### 代码参考1：TopN计算

```
	numTop = mathutil.MinUint32(sampleNDV, numTop) // Ensure numTop no larger than sampNDV.
	// Only element whose frequency is not smaller than 2/3 multiples the
	// frequency of the n-th element are added to the TopN statistics. We chose
	// 2/3 as an empirical value because the average cardinality estimation
	// error is relatively small compared with 1/2.
	var actualNumTop uint32
	for ; actualNumTop < sampleNDV && actualNumTop < numTop*2; actualNumTop++ {
		if actualNumTop >= numTop && sorted[actualNumTop].cnt*3 < sorted[numTop-1].cnt*2 {
			break
		}
		if sorted[actualNumTop].cnt == 1 {
			break
		}
		sumTopN += sorted[actualNumTop].cnt
	}
```

### 代码参考2：缺省值计算
```
func calculateDefaultVal(helper *topNHelper, estimateNDV, scaleRatio, rowCount uint64) uint64 {
	sampleNDV := uint64(len(helper.sorted))
	if rowCount <= (helper.sampleSize-helper.onlyOnceItems)*scaleRatio {
		return 1
	}
	estimateRemainingCount := rowCount - (helper.sampleSize-helper.onlyOnceItems)*scaleRatio
	return estimateRemainingCount / mathutil.MaxUint64(1, estimateNDV-sampleNDV+helper.onlyOnceItems)
}
```

## 小结
1. 大数据量下，Count-Min Sketch的误差太大，可能并不适合在数据库用于基数估算
2. TiDB在直方图的桶中记录了不同值个数的方法值得借鉴
