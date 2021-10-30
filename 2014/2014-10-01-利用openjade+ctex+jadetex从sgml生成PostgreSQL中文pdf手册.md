## 1.背景

去年底的时候PostgreSQL中国社区组织了PostgreSQL 9.3手册的翻译工作，翻译中的html版的中文手册可以网站 ( http://58.58.25.191:8079/doc/html/9.3.1_zh/)在线浏览。如今大部分的页面已经翻译完成（但校对比较滞后），因此生成pdf版手册的任务就提上了日程。



## 2.概述

PostgreSQL的手册文档是用sgml格式的docbook写的，docbook本身不带显示格式，但可以通过工具输出成各种常用的文档格式，比如html和pdf。其中转换到pdf的过程分为两步。首先，用openjade转到tex格式,然后再用pdfjadetex转成pdf格式。对于英文文档，这个过程很容易，调用PG的make脚本就可以了。但这两个工具对中文的支持不太好，所以要把PG社区翻译后的PostgreSQL手册输出成pdf就比较费事了。以下是经过调查和不断尝试总结出的步骤。



## 3.步骤

### 3.1 将sgml编译成tex

参考PG的手册，在Linux下装上编译文档所必须的软件，然后进入源码根目录。
http://www.postgresql.org/docs/9.4/static/docguide-toolsets.html
执行下面的命令把sgml编译成tex格式

```
./configure
cd doc/src/sgml
make postgres-A4.tex-pdf
```


注1）这一步的要点是sgml必须是GB2312编码，不能是UTF8，否则openjade会出错。可参考http://blog.chinaunix.net/uid-20726500-id-3998759.html。
注2）Windows下编译出来的tex-pdf中文字符都变成了“\Character{20840}”这样的形式，后面不好处理，所以不能在Windows上编译。



### 3.2手工修补postgres-A4.tex-pdf

从现在开始可以转到Windows上操作。上面生成出来的postgres-A4.tex-pdf有些小问题，需要修补一下。 先把上一步生成的 postgres-A4.tex-pdf 传到Windows上 ，再用编辑器打开进行编辑。在 postgres-A4.tex-pdf中找到下面这处，进行修改。

```
{\def\fFamName{Times-New-Roman}}Copyright牘燶Node%
```

==》

```
{\def\fFamName{Times-New-Roman}}Copyright **\Entity{copy}** \Node%
```



再用全局替换，把所有"燶"改成"\"

```
燶
```

==》

```
\
```



### 最后把postgres-A4.tex-pdf存成UTF8编码（后面的处理需要）。

注3）英文sgml编译时也会有这些字符，但最后生成的英文pdf没有问题（可能由于英文是单字节字符的原因，这些字符没有影响后面pdftex的生成pdf）。不知道这是不是openjade的bug。



### 3.3安装ctex

在Windows上下载并安装ctex作为tex到pdf转换的集成环境。
http://www.ctex.org/CTeXDownload

注4）Linux上可以安装texlive集成环境，但是配置pdftex引擎的中文字体很麻烦，xetex引擎虽然对中文支持的很好，但是一旦用上jadetex格式对中文的支持就有问题了。



### 3.4下载安装jadetex包

从开始菜单找到：CteX->MiKTeX->Maintenance->Package Manager，然后从List里找到jadetex，点击鼠标右键，再点"Install"进行安装。



### 3.5编辑jadetex.ltx

安装jadetex后进入jadetex所在目录，打开其中的jadetex.ltx进行编辑，使其可以支持中文。
C:\CTEX\UserData\tex\jadetex\base\jadetex.ltx

修正1：

点击(此处)折叠或打开

```
\documentclass{minimal}
\RequirePackage{array}[1995/01/01]
```

==>

```
\documentclass{minimal}
\usepackage{CJKutf8}
\RequirePackage{array}[1995/01/01]
```


修正2：

```
\RequirePackage[dsssl]{inputenc}[1997/12/20]
```

==》

```
%\RequirePackage[dsssl]{inputenc}[1997/12/20]
```


修正3：

```
\RequirePackage[implicit=true,colorlinks,linkcolor=black,bookmarks=true]{hyperref}[2000/03/01]
```

==》

```
\RequirePackage[unicode,implicit=true,colorlinks,linkcolor=black,bookmarks=true]{hyperref}[2000/03/01]
```


修正4：

```
\fi
\enddocument}
```

==》

```
\end{CJK}
\enddocument}
```


修正5：

```
\fi
\makeatletter
```

==》

```
\fi
\begin{CJK}{UTF8}{song}
\makeatletter
```

最后一个{song}是指中文使用的字体名，如果你喜欢可以换成别的字体，前提是ctex上得安装了那个字体。



### 3.6生成pdf

进入postgres-A4.tex-pdf文件所在目录。如果目录中有上次编译残留的下列文件，先将它们删除。
postgres-A4.out
postgres-A4.log
postgres-A4.aux

执行下面的命令就可以生成postgres-A4.pdf了。（执行时间大概有20几分钟）

```
pdflatex --hash-extra=2000000 --job-name=postgres-A4 \input jadetex.ltx \input postgres-A4.tex-pdf
pdflatex --hash-extra=2000000 --job-name=postgres-A4 \input jadetex.ltx \input postgres-A4.tex-pdf
pdflatex --hash-extra=2000000 --job-name=postgres-A4 \input jadetex.ltx \input postgres-A4.tex-pdf
```



注5）上面相同的命令执行了3次，这不是笔误，后面2次执行是为了生成书签和交叉引用。
注6）--hash-extra=2000000 的作用是为了扩大hash的size，如果不设置，可能会报出下面的错误。（通过命令“ initexmf --edit-config-file=pdflatex”修改配置文件，设置 hash_extra=2000000也能达到相同目的）
*! TeX capacity exceeded, sorry [hash size=215000].*

最后 生成的pdf中有些表格的显示异常，部分内容显示到格子外面去了，对照了下官方的英文pdf，发现也有相同的问题（PG的手册中也提到这个问题，似乎没什么很好的解决办法，只能手工在sgml适当的位置加空格让tex可以断行）。而且这个pdf文件比较大，有27M， 但PG官网上的英文pdf手册只有6M,于是尝试用试用版ORPALIS PDF Reducer优化了一下，可以缩小到12M。另外，pdf中保留了所有的链接引用（比如每个SQL命令最下方的"参见"），能方便跳转，但是链接文字和普通文字在外观上没有任何区别，只有把鼠标移上去才能知道那是链接。



## 4.写在最后

本文用到一些软件或技术都是比较过时 ，像 sgml格式的docbook(取而代之的是xml格式的docbook) 和pdftex(现在都推荐使用可以直接使用OS字体的xetex)，它们对中文的支持不太好，所以才这么折腾。但是PG现在就是用的这些 ，没办法。
除了本文的方法外，还可以先生成html再生成pdf。这种方法比较容易实施，但是生成的pdf内容是网页风格的，不像是一本“书”。 看了下日本PG用户会的官网，他们并没有提供pdf版的手册，只提供在线的html，打包的html和sgml。但在Symfoware(Open)的安装包里带了一份PG的 日文版 pdf手册，从风格上可以看出是通过html生成的（看了下文档属性，发现是用Acrobat Web Capture 10.0生成的）， 效果也不错。



## 5.补充

在编译9.6.0的pdf时，遇到了下面的错误。

```
! TeX capacity exceeded, sorry [main memory size=5000000]
```

奇怪的是在pdflatex的命令行里设置" - - main - memory = 5000000"没有任何作用，于是按照以下方法回避



1. 执行以下命令

   ```
   initexmf --edit-config-file=pdflatex 
   ```

2. 在打开的编辑器中编辑pdflatex.ini

   ```
   main_memory=5000000 
   extra_mem_bot=5000000 
   pool_size=5000000 
   buf_size=5000000 
   ```

3. 执行命令更新LaTeX格式文件

   ```
   initexmf --dump=pdflatex
   ```

## 6.参考

- 《The TeXBook》
- http://www.texdoc.net/
- http://texdoc.net/texmf-dist/doc/latex/lshort-chinese/lshort-zh-cn.pdf
- http://texdoc.net/texmf-dist/doc/latex/base/fntguide.pdf
- http://texdoc.net/texmf-dist/doc/fonts/fontinst/manual/fontinst.pdf
- http://texdoc.net/texmf-dist/doc/latex/latex2e-help-texinfo/latex2e.pdf
- http://texdoc.net/texmf-dist/doc/otherformats/jadetex/base/index.html
- http://texdoc.net/texmf-dist/doc/latex/cjk/doc/CJK.txt
- http://lyanry.is-programmer.com/posts/332.html
- http://www.study-area.org/tips/latex/pdftex.html
- http://www.math.zju.edu.cn/ligangliu/LaTeXForum/tex_setup_chinese.htm
- http://bbs.ctex.org/forum.php?mod=viewthread&tid=40981
- http://ar.newsmth.net/thread-3984539b999fc4.html
- https://github.com/matlab2tikz/matlab2tikz/wiki/TeX-capacity-exceeded,-sorry

