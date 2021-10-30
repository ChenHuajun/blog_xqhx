# 关于docbook sgml的中文字符支持

最近在参与PostgreSQL中国社区的文档中文化。PG的文档是一堆基于docbook的sgml文件。这些sgml可以通过工具转成html，pdf等各种不同格式。
这即是docbook所倡导的“内容和格式的分离”。然而当我尝试把翻译好的一个sgml文件用openjade转成html时，发现openjade报一堆类似的错误:"non SGML character number nnn"。
针对这一问题，经过调查，得到下面这些线索。



## 调查与分析

### 1. docbook的SGML中规定了使用的字符集,超出编码范围报错

类似于xml的 <?xml version="1.0" encoding="UTF-8" ?> ，sgml也可以指定字符集，但形式上要复杂的多。
以下是docbook 4.2默认的字符集定义:

docbook.dcl

```
...
    BASESET
  "ISO 646:1983//CHARSET International Reference Version (IRV)//ESC 2/5 4/0"
    DESCSET
                    0 9 UNUSED
                    9 2 9
                   11 2 UNUSED
                   13 1 13
                   14 18 UNUSED
                   32 95 32
                  127 1 UNUSED

    BASESET
  "ISO Registration Number 100//CHARSET ECMA-94 Right Part of Latin Alphabet Nr. 1//ESC 2/13 4/1"
    DESCSET
                  128 32 UNUSED
                  160 96 32
...
```

在上面标有"UNUSED"的code范围的字符为非法字符，遇到这些字符sgml解释器就会报错："non SGML character number nnn"。
这也就是前面提到的错误的原因。



### 2. Bruce Momjian在PG社区的ML里表示sgml不支持UTF8

http://www.postgresql.org/message-id/200908131914.n7DJETG02802@momjian.us

```
...
we cannot use UTF8 because SGML Docbook
        does not support it
          http://www.pemberley.com/janeinfo/latin1.html#latexta
...
```

我一开始没充分理解它的含义，我以为它绝了中文字符在sgml中出现可能性，我觉得这不太可能，于是没有太理会。



### 3. linux 中文doc计划使用字符替换的方式回避中文字符问题

linux 中文doc计划使用字符替换的方式回避中文字符问题。
http://www.linux.org.tw/CLDP/OLD/zh-sgmltools-1.html

```
...
套件中包含一工具程式 mb2a, 可自標準輸入或檔案中讀取資料，將其中的 BIG5 或 GB 字元編碼成 @=XXXX 
的形式，其中 XXXX 就是該字的 BIG5 或 GB 碼。 這個程式同時也能將這種編碼的資料予以解碼。
...
```

我相信这个方法一定可以回避中文不能识别的问题，但我觉得这个方法有点土，应该有更优雅的方法。
而且我查到的资料比较老了，也许他们现在也不这么干了。



### 4.  有人尝试在SGML声明中重新指定字符集解决这个问题

看到有日本人尝试使用环境变量SP_ENCODING=utf-8，加上包含日文字符集自定义SGML声明实现装换，但是对某些SP_ENCODING=utf-8 处理不了的字符仍然会出错。
http://listserv.linux.or.jp/pipermail/vine-users/2010-October/000330.html

```
...
環境変数 SP_ENCODING に utf-8 をセットして，
添付ファイルを文書型（DOCTYPE）が書いてある
ファイルの先頭に挿入すると，日本語で書いてある
UTF-8のDocBook SGML文書をjadeで処理できました．
...
いくつか警告が表示されます．またリリースノートなどに
書いてある人名のいくつかに SP_ENCODING=utf-8 では
扱えない文字があるようです．その部分を直さないと日本語の
有無に関わらず"非SGML数字"と表示されてエラーになりました．
...
```


japan-docbook.dcl

```
...
CHARSET
BASESET
"ISO Registration Number 1//CHARSET C0 set of ISO 646//ESC 2/1 4/0"
DESCSET 0 9 UNUSED
     9 2 9
     11 2 UNUSED
     13 1 13
     14 18 UNUSED

BASESET
"ISO Registration Number 14//CHARSET ISO 646 Japanese Version//ESC 2/8 4/10"
DESCSET
32 95 32
127 1 UNUSED

BASESET
"ISO Registration Number 87//CHARSET JIS X 0208-1990//ESC 2/6 4/0 ESC 2/4 4/2"

DESCSET
41344 33 UNUSED
41377 94 8481
...
```


这个方法似乎是一条不错的思路。我做了些尝试，试图修改字符集的定义去欺骗openjade，最终发现这不太容易（也许这条路可行，谁知道呢？）。



## 无意的发现

最后的最后，无意中用GBK编码(之前一直使用UTF8编码)的sgml文件尝试，惊讶的发现openjade居然安静地完成了到html的转换。
什么个情况？再研究一下GBK的字符集定义，发现了其中的奥秘。

GBK的编码范围见下表，其中的GBK/1和GBK/2水准的汉字，即GB 2312-80用通常方法编码的区域，
正好落在docbook默认字符集的合法编码范围内。所以在GBK编码下这部分汉字会被openjade误以为是合法的扩展ACSII码，而欣然接受。

但是其他汉字就唬弄不了openjade了。幸运的是我们常用的汉字都在GBK/1和GBK/2（或者说gb2312）范围内，GBK相对于gb2312扩充的
汉字没那么常用，比如繁体字。至少对于PG文档的中文化，这些汉字应该够用了。

**GBK的编码范围:**

| 范围       | 第1字节 | 第2字节        | 编码数 | 字数   |
| ---------- | ------- | -------------- | ------ | ------ |
| 水准 GBK/1 | A1–A9   | A1–FE          | 846    | 717    |
| 水准 GBK/2 | B0–F7   | A1–FE          | 6,768  | 6,763  |
| 水准 GBK/3 | 81–A0   | 40–FE (7F除外) | 6,080  | 6,080  |
| 水准 GBK/4 | AA–FE   | 40–A0 (7F除外) | 8,160  | 8,160  |
| 水准 GBK/5 | A8–A9   | 40–A0 (7F除外) | 192    | 166    |
| 用户定义   | AA–AF   | A1–FE          | 564    |        |
| 用户定义   | F8–FE   | A1–FE          | 658    |        |
| 用户定义   | A1–A7   | 40–A0 (7F除外) | 672    |        |
| 合计:      |         |                | 23,940 | 21,886 |



## 结论

问题算是解决，翻好的sgml文件使用GBK(或gb2312)编码而不是utf8存档，只要是gb2312编码范围内的字符都没有问题。
到此我突然明白了日本PG社区翻译后的sgml文件为什么是euc_jp编码而不是sjis或utf8，原来他们也是这么干的呀！
此外，最新的docbook5.0已经只有xml格式了，也许什么时候pg社区也会与时俱进放弃sgml改用xml。
我们知道xml要支持不同编码很容易，如果使用xml格式的docbook的话，中文字符的支持就简单了。



## 参考资料

http://xml.coverpages.org/wlw11.html
http://zh.wikipedia.org/wiki/GBKhttp://www.study-area.org/tips/docw/docwrite.html