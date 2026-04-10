# analyze_map.bat

分析 Keil MDK 编译生成的 `.map` 文件，输出内存占用报告和竖状地址分配图。

## 用法

```
analyze_map.bat [file.map] [brief|verbose]
```

| 参数 | 说明 |
|------|------|
| `file.map` | 可选。指定 `.map` 文件路径。省略时自动在 `Objects\` 和 `Listings\` 子目录中查找 |
| `brief` | 精简模式（**默认**）：只显示内存占用概览、警告和竖状地址图 |
| `verbose` / `v` | 详细模式：显示全部分析章节 |

### Keil 编译后自动运行

在 Keil 中配置编译完成后自动调用此脚本：

1. 打开 **Options for Target 'xxx'**
2. 切换到 **User** 选项卡
3. 在 **After Build/Rebuild** 区域勾选 **Run #1**，填入：

   ```
   analyze_map.bat @L\@L.map
   ```

> `@L` 是 Keil 内置宏，会自动展开为 Linker 输出路径和文件名（如 `Objects\project.map`），无需手动指定路径。

### 示例

```bat
:: 精简模式（自动查找 map 文件）
analyze_map.bat

:: 指定文件，精简模式
analyze_map.bat build\project.map

:: 指定文件，详细模式
analyze_map.bat build\project.map verbose
```

## 输出内容

### 精简模式（brief）

| 章节 | 内容 |
|------|------|
| 内存占用概览 | Code / RO-data / RW-data / ZI-data 字节数，ROM 和 RAM 合计 |
| 警告 | 大模块提示、内存占用超限告警、Stack 过小警告 |
| 竖状地址分配图 | FLASH 和 RAM 的实际地址布局，含各段起止地址 |

### 详细模式（verbose）在精简内容基础上增加

| 章节 | 内容 |
|------|------|
| 2. Load Regions | 加载区基地址、已用/最大空间及占用率 |
| 3. Execution Regions | Flash 和 RAM 执行区列表 |
| 4. Stack & Heap 分析 | Stack/Heap 大小、地址范围、RAM 占比、溢出风险评估 |
| 5. 模块大小排名 | 按 ROM 和 RAM 占用排名前 25 的目标文件 |
| 6. 库文件汇总 | 各静态库的 Code/RO/RW/ZI 占用 |
| 7. Section 类型分析 | 按 section 名称和类型统计大小 |
| 8. 区域 Section 明细 | 每个执行区内的 section 分组统计 |
| 9. 横向内存图 | 各执行区占用率的横向进度条 |
| 10. ROM 组成 | Code / RO-data / RW-init 在 Flash 中的比例 |
| 11. 用户代码 vs 库 | 用户代码与库代码的 ROM 占比对比 |

## 竖状地址分配图示例

```
  FLASH  [base:0x08000000  cap:128.00 KB]     RAM  [base:0x20000000  cap:20.00 KB]

  0x08020000 +----------------------+     0x20005000 +----------------------+
             |                      |                |        (free)        |
             |        (free)        |     0x200030E8 +----------------------+
             |      (96.34 KB)      |                |        Stack         |
  0x08007EA0 +----------------------+     0x20002CE8 +----------------------+
             |        RW-init       |                |        ZI/BSS        |
  0x08007C60 +----------------------+     0x20000240 +----------------------+
             |        RO-data       |                |        RW-data       |
  0x08007B6C +----------------------+     0x20000000 +----------------------+
             |         Code         |
  0x08000000 +----------------------+
```

- 地址从下（低）到上（高）排列
- 每条分隔线左侧标注实际十六进制地址
- Flash 段边界从已解析的 section 条目推算，精确到 section 粒度
- RAM 段包含 RW-data、ZI/BSS、Heap（如存在）、Stack

## 颜色说明

| 颜色 | 含义 |
|------|------|
| 青色 | Code（程序代码） |
| 绿色 | RO-data（只读常量） |
| 黄色 | RW-init / RW-data（初始化变量） |
| 白色 | ZI/BSS（未初始化变量） |
| 红色 | Stack |
| 品红 | Heap |
| 深灰 | 空闲空间 |

占用率超过 90% 显示红色，超过 70% 显示黄色。

## 兼容性

- 支持 **ARMCC5**（ARM Compiler 5，三列 hex 格式：`exec_addr load_addr size`）
- 支持 **ARMCC6**（ARM Compiler 6，两列 hex 格式：`exec_addr size`）
- 需要 Windows PowerShell 5.1 或以上
- 无需安装额外依赖
