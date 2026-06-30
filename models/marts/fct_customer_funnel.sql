-- ================================================================
-- fct_customer_funnel · 客户漏斗事实表 (customer funnel fact table)
-- 粒度 grain：一行 = 一个客户 (one row per customer)
-- ================================================================
--
-- 【这张表要回答的业务问题】老板想知道两件事，且都要分 iOS / Android 看：
--   问题1（转化 vs 放弃 / convert vs abandon）：
--       到达"结账页 checkout"的客户里，多少最后真下单了、多少放弃了？哪个平台转化更好？
--   问题2（下单耗时 / time to order）：
--       成功下单的客户，从"第一次跟 App 互动"到"真正下单"平均花多久？两平台有差异吗？
--
-- 【客户漏斗 funnel 四步】(都是 website_events.event_name 的取值)
--       page_hit  →  add_to_cart  →  go_to_checkout  →  place_order
--       浏览页面      加入购物车        去结账页           下单
--
-- 【为什么需要这张表 / 它在干嘛】
--   源表 stg_mfs_website_events 是"一行一个事件"(一个客户很多行)。
--   但上面两个问题都在问"每个客户怎样" → 要把"一客户多事件"压成"一客户一行"，
--   每客户带：① 各步首次时间 ② 到没到结账/下没下单(布尔) ③ 下单耗时 ④ 平台。
--   这张"一行一客户、面向分析"的表 = mart 层事实表(fact)，故命名 fct_。
--
-- 【3 个影响口径的数据现实】(建表前探数发现的，不是拍脑袋)
--   · page_hit 稀疏(572 行，比 add_to_cart 的 999 个客户还少) →
--     "首次互动"不能只看 page_hit(否则多数客户没起点)，起点 page_hit 没有就退 add_to_cart。
--   · raw_flower_orders 只 8 行、和 place_order 事件(2960)对不上、不可靠 →
--     "下单"信号一律以 website_events 里 event_name='place_order' 的事件为准。
--   · platform 只有 'Android' / 'iOS' 两种值，无空值。
--
-- 【下游 downstream】
--   mart_platform_funnel_metrics 对本表"按 platform 分组聚合"，用 reached_checkout /
--   placed_order 两个布尔列 countif 数人数、算转化率 → 本表必须先把这两个布尔算好。
--
-- 【整体结构 / 数据流】(dbt 习惯：import → 逐步加工 → final 装配 → 输出)
--   events            取数：从 staging 取要用的列(还是一行一事件)
--     ├─ firsts            压成一行一客户 + 各步首次时间   (GROUP BY 聚合)
--     ├─ latest_platform   每客户"最近一次"的平台         (窗口函数 row_number)
--     └─ platform_at_order 每客户"下单那刻"的平台         (窗口函数 row_number)
--           └─ final  把几块按 customer_id 拼起来 + 算派生列(耗时/布尔/平台)
--                 └─ select * from final   ← 最终输出(model 必须有这句)
-- ================================================================

with

-- ----------------------------------------------------------------
-- events —— 取数 / import 层
-- ----------------------------------------------------------------
-- 只从 staging 取"下游真正要用的 4 列"，不做任何计算。
-- 为什么是这 4 列(从业务问题倒推；源表 9 列只取这几个)：
--   customer_id —— 粒度键。本表一行一客户，必须靠它分组/聚合。
--   event_name  —— 区分漏斗四步，后面条件聚合的判断条件。
--   event_time  —— 算"各步首次时间"和"下单耗时"都要它(秒级时间戳)。
--   platform    —— 业务问题要分 iOS/Android，必须一路带下去，否则后面没法分平台。
-- 没取的(event_id/campaign_id/additional_details/total_value/event_date)：
--   都答不上"下游哪步用它" → 不取。如金额(total_value)跟"转化率/耗时"无关。

events as (
    select
       customer_id,
       event_name,
       event_time,
       platform
    from {{ref('stg_mfs_website_events')}}
),

-- ----------------------------------------------------------------
-- firsts —— "一客户多事件"压成"一客户一行" + 各步首次时间   ⭐条件聚合
-- ----------------------------------------------------------------
-- 核心一步：grain 在这里从"一行一事件"变成"一行一客户"。
-- 逐层拆 min(if(event_name='page_hit', event_time, null)) ：
--   ① if(条件,A,B)：是 page_hit 的行→给它的 event_time；不是→给 null。
--      该客户这列变成 [null, null, 某page_hit时间, null, ...]。
--   ② min(...)：聚合且"MIN 自动忽略 null"→在剩下的 page_hit 时间里取最早
--      = 该客户"第一次 page_hit"。(从没 page_hit→全 null→结果 null)
--   ①+② = "条件聚合"：只对满足条件的行做聚合。四个漏斗步各来一遍。
-- group by 1 = 按第 1 列(customer_id)分组(=group by customer_id 简写)，
--   配 min 把"一客户多行"折叠成"一客户一行"，四个首次时间横排同一行。
firsts as(
    select
        customer_id,

        min(if(event_name = 'page_hit', event_time, null)) as first_page_hit_time,
        min(if(event_name = 'add_to_cart', event_time, null)) as first_add_to_cart_time,
        min(if(event_name = 'go_to_checkout', event_time, null)) as first_go_to_checkout_time,
        min(if(event_name = 'place_order', event_time, null)) as first_place_order_time
    from events
    group by 1
),

-- ----------------------------------------------------------------
-- latest_platform —— 每客户"最近一次"用的平台   ⭐窗口函数
-- ----------------------------------------------------------------
-- 为什么需要：一客户可能多次互动甚至换设备，platform 不是固定值。
-- 取"最近一次事件"的平台，作为该客户平台的兜底(人人都有)。
-- 从里往外读 row_number() over(partition by customer_id order by event_time desc)：
--   · 窗口函数：不像 group by 合并行，它保留每一行、只额外贴个编号。
--   · partition by customer_id：按客户各分各的窗，各自编号。
--   · order by event_time desc：窗内按时间从晚到早排。
--   · row_number()：排好后编号 1,2,3...→rn=1 = 该客户"最近"那条事件。
--   · 内层 where platform is not null：排序前剔空平台，免得空值占了 rn=1。
-- 外层 where rn=1：每客户只留最近那条，取它的 platform，起名 latest_platform。
latest_platform as (
    select
        customer_id,
        platform as latest_platform
    from(
        select
            customer_id,
            platform,
            row_number() over(partition by customer_id order by event_time desc) as rn
        from events
        where platform is not null
    )
    where rn = 1 --rn是row number的意思，這裡是取每個customer_id最新的一筆資料
),
-- 先列出来每个用户的event time对应的platform，然后给这些event排号，然后rn=1就是只抽第一个，latest_platform就是每个用户最新的event对应的platform


-- ----------------------------------------------------------------
-- platform_at_order —— 每客户"下单那一刻"用的平台
-- ----------------------------------------------------------------
-- 和 latest_platform 几乎一样，唯一区别：内层多了 event_name='place_order'，
--   即只在"下单事件"里取最近一条 → 该客户下单时所在平台(更准)。
-- 没下过单的客户在这个 CTE 里"没有行"(后面 left join 进 final 接成 null)。
-- 分工：platform_at_order 更准但只下单者有；latest_platform 兜底人人有。
platform_at_order as(

    select
        customer_id,
        platform as platform_at_order
    from(
        select
            customer_id,
            platform,
            row_number() over(partition by customer_id order by event_time desc) as rn
        from events
        where event_name = 'place_order' and platform is not null
    )
    where rn = 1
),

-- ----------------------------------------------------------------
-- final —— 装配 / assemble：按 customer_id 把上面几块拼起来 + 算派生列
-- ----------------------------------------------------------------
-- 以 firsts 为主干(一行一客户)，left join 两个平台 CTE。
-- 为什么 left join 不用 inner：left 保留 firsts 里所有客户，右表没对应行就填 null，
--   不丢没下单/没记录平台的客户。三张都一行一客户(key 唯一)→一对一拼，不放大行数。
  final as (

      select
          firsts.customer_id,

          -- 各步首次时间(null = 该客户从没走到这一步)
          firsts.first_page_hit_time,
          firsts.first_add_to_cart_time,
          firsts.first_go_to_checkout_time,
          firsts.first_place_order_time,

          -- 两个布尔旗标(flag)：把"首次时间这列空不空"翻译成"到没到这步"。
          -- X is not null 产出 true/false：有值=走到过=true；null=没到过=false。
          -- 视频在 fct 这步没加，但下游 mart 要 countif 数这两列，故建 fct 时就一起加。
          firsts.first_go_to_checkout_time is not null as reached_checkout,
          firsts.first_place_order_time is not null as placed_order,

          -- 下单耗时(秒)：只对下单者算。CASE 自上而下命中第一个为真分支：
          --   分支1：没下单 → null(只对下单者算)
          --   分支2：连起点都没有(page_hit、add_to_cart 都空) → null
          --   else：timestamp_diff(终, 起, second) 算相差几秒(晚的在前、早的在后)
          --         终=首次下单时间；起=首次互动 coalesce(page_hit, add_to_cart)：
          --         优先第一次 page_hit，没有(稀疏!)退第一次 add_to_cart。
          --   ⚠ 分支2 与 else 的 coalesce 必须同一串，否则"判空口径"和"实算口径"会裂。
          case
              when firsts.first_place_order_time is null then null
              when coalesce(firsts.first_page_hit_time, firsts.first_add_to_cart_time) is null then null
              else timestamp_diff(
                  firsts.first_place_order_time,
                  coalesce(firsts.first_page_hit_time, firsts.first_add_to_cart_time),
                  second
                  -- TIMESTAMP_DIFF(终, 起, 单位) —— 两个时间差多少
              )
          end as time_to_order_seconds,

          -- 平台：优先"下单时"的，没有(没下单)退"最近一次"的，都没→null。
          -- coalesce(a, b) = 从左到右第一个非空值。
          coalesce(platform_at_order.platform_at_order, latest_platform.latest_platform) as platform
--COALESCE(a, b) —— "第一个非空"
      from firsts
      left join platform_at_order on firsts.customer_id = platform_at_order.customer_id
      left join latest_platform   on firsts.customer_id = latest_platform.customer_id

  )


-- 最终输出：把 final 整张吐出来。model 必须以一句真正的 select 结尾(光定义 CTE 不输出会报错)。
-- marts 配了 +materialized: table，故这张落成真表(不是 view)。
select * from final
