# 分层约束一致性（前端 / 接口 / 数据库）

同一个约束在三处各写一遍，**任何一处不一致都是缺陷**。

典型事故：前端限 100 字、后端限 120 字、DB 是 `varchar(50)` —— 用户填得进去、接口收得下、入库报 `Data too long`。

## 1 拉出三层的真实值（不看注释）

| 层 | 从哪取 |
|---|---|
| 前端 | 表单 `rules`、`maxlength`、`precision`、`min/max`、下拉选项数组 |
| 接口 | DTO 上的 `@Size` / `@NotNull` / `@Digits` / `@Min` / `@Max`、枚举类 |
| 数据库 | `information_schema.COLUMNS` |

```sql
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE,
       CHARACTER_MAXIMUM_LENGTH AS len, NUMERIC_PRECISION AS p, NUMERIC_SCALE AS s,
       IS_NULLABLE, COLUMN_COMMENT
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = '<库名>' AND TABLE_NAME = '<表名>'
ORDER BY ORDINAL_POSITION;
```

## 2 一致性矩阵（每个可编辑字段一行）

| 字段 | 前端 | 接口 | 数据库 | 真实上限 | 判定 |
|---|---|---|---|---|---|
| 名称 | maxlength=100 | `@Size(max=120)` | `varchar(50)` | 50 | 不一致 |
| 金额 | precision=2 | `BigDecimal` 无注解 | `decimal(18,2)` | 18,2 | 一致 |
| 状态 | 下拉 3 项 | 枚举 3 值 | `tinyint` + 字典 3 条 | 3 | 一致 |

## 3 八条判定规则

1. **取最严的一层当真实上限**，其余对齐，或「宽进严出」并在接口层截断 + 返回可读错误
2. 前端 > 后端 → 能填不能存，**体验缺陷**
3. **后端 > 数据库 → 入库报错，数据缺陷，最高优先级**
4. 类型不一致（前端 number / 后端 String / DB varchar）→ 必测 `0 / 负数 / 小数 / 科学计数 / 超大值`
5. 布尔三套写法（`0/1`、`true/false`、`Y/N`）混用时，落库值只能有一套
6. 必填：前端 ⊆ 后端 ⊆ DB `NOT NULL`，反向放宽即缺陷
7. 枚举：前端选项 ⊆ 后端枚举 ⊆ 字典表
8. 长整型 ID：接口必须返回字符串，前端不能当数字算（精度丢失）

## 4 必做动作

- 绕过前端**直接打接口**传越界值（超长字符串、超范围数字、非法枚举、超精度小数）
- 从库 **SELECT 实际存进去的东西**，比对是否被截断、四舍五入、隐式转换
- 分清三种拦截位置：前端拦住（体验）/ 后端拦住并给明确文案（合格）/ DB 截断或报错（缺陷）

## 5 常见断点

- 前端 `maxlength` 设了，后端没注解 → 直接打接口能塞进去
- 后端 `@Size(max=120)`，DB `varchar(100)` → 121~200 字直接 500
- 金额前端两位小数，DB `decimal(10,4)` → 页面显示被截断
- 状态用字符串传，DB 存 `tinyint` → 隐式转换失败或落成 0
