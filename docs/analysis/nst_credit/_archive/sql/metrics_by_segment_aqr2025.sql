-- Источник: рабочий скрипт AQR-2025 (сегментация / расчёт метрик).
-- Сохранён как есть для истории; замечания и предложения — в SQL_REVIEW.md.
-- Имена таблиц и схем — рабочие; данных банка в репозитории нет.

WITH B1A AS (
    SELECT 
        gg.loan_id_kr,
		gg.portfolio,
        fg.segment_afr,
        CAST(gg.stage_b AS FLOAT) AS stage_b,
		CAST(gg.ccf AS FLOAT)ccf,
        CAST(gg.ltv AS FLOAT)ltv,
        CAST(gg.lgd AS FLOAT)lgd,
        CAST(gg.pd_c12 AS FLOAT)pd_c12,
        CAST(gg.pd_cl AS FLOAT)pd_cl,
        CAST(gg.pd_ol AS FLOAT)pd_ol,
        CASE 
            WHEN CAST(gg.stage_b AS FLOAT) = 4 THEN 3
            WHEN gg.stage_b = '1111111111111' THEN 1
            ELSE CAST(gg.stage_b AS FLOAT)
        END AS stage_b_new,

        CASE WHEN gg.ccf IN ('1111111111111','9999999999999') THEN 0 ELSE CAST(gg.ccf AS FLOAT) END AS ccf_new,
        CASE WHEN gg.lgd IN ('1111111111111','9999999999999') THEN 0 ELSE CAST(gg.lgd AS FLOAT) END AS lgd_new,
        CASE WHEN gg.pd_c12 IN ('1111111111111','9999999999999') THEN 0 ELSE CAST(gg.pd_c12 AS FLOAT) END AS pd_c12_new,
        CASE WHEN gg.pd_cl IN ('1111111111111','9999999999999') THEN 0 ELSE CAST(gg.pd_cl AS FLOAT) END AS pd_cl_new,
        CASE WHEN gg.pd_ol IN ('1111111111111','9999999999999') THEN 0 ELSE CAST(gg.pd_ol AS FLOAT) END AS pd_ol_new,

        CAST(gg.offbal AS FLOAT) AS offbal,
        CAST(gg.ead AS FLOAT) AS ead,
        CAST(gg.provisions AS FLOAT) AS provisions,

          CAST(gg.od AS FLOAT)
        + CAST(gg.od_del AS FLOAT)
        + CAST(gg.interest AS FLOAT)
        + CAST(gg.interest_del AS FLOAT)
        + CAST(gg.correction AS FLOAT)
        + CAST(gg.disc_prem AS FLOAT)
        + CAST(gg.penalty AS FLOAT) AS summa_zadol,

        'B1A' AS shablon
    FROM [CL_PORTFOLIO].[dbo].[AQR2025_B1A_2024_Q4] gg
    LEFT JOIN [personal_tables].[dbo].[RA_NST_segment_AQR2025] fg -- есть скрипт ниже закомментированный
        ON gg.loan_id_kr = fg.loan_id_kr
    WHERE gg.is_del = '0'
),
B1B AS (
    SELECT 
        dd.loan_id_kr,
		dd.portfolio,
        sd.segment_afr,
        CAST(dd.stage_b AS FLOAT) AS stage_b,
		CAST(dd.ccf AS FLOAT)ccf,
        CAST(dd.ltv AS FLOAT)ltv,
        CAST(dd.lgd AS FLOAT)lgd,
        CAST(dd.pd_c12 AS FLOAT)pd_c12,
        CAST(dd.pd_cl AS FLOAT)pd_cl,
        CAST(dd.pd_ol AS FLOAT)pd_ol,
        CASE WHEN CAST(dd.stage_b AS FLOAT) = 4 THEN 3 
		     WHEN dd.stage_b = '1111111111111' THEN 1
		     ELSE CAST(dd.stage_b AS FLOAT) END AS stage_b_new,

        CASE WHEN dd.ccf IN ('1111111111111','9999999999999') THEN 0 ELSE CAST(dd.ccf AS FLOAT) END AS ccf_new,
        CASE WHEN dd.lgd IN ('1111111111111','9999999999999') THEN 0 ELSE CAST(dd.lgd AS FLOAT) END AS lgd_new,
        CASE WHEN dd.pd_c12 IN ('1111111111111','9999999999999') THEN 0 ELSE CAST(dd.pd_c12 AS FLOAT) END AS pd_c12_new,
        CASE WHEN dd.pd_cl IN ('1111111111111','9999999999999') THEN 0 ELSE CAST(dd.pd_cl AS FLOAT) END AS pd_cl_new,
        CASE WHEN dd.pd_ol IN ('1111111111111','9999999999999') THEN 0 ELSE CAST(dd.pd_ol AS FLOAT) END AS pd_ol_new,

        CAST(dd.offbal AS FLOAT) AS offbal,
        CAST(dd.ead AS FLOAT) AS ead,
        CAST(dd.provisions AS FLOAT) AS provisions,

        CAST(dd.correction AS FLOAT)
        + CAST(dd.disc_prem AS FLOAT)
        + CAST(dd.penalty AS FLOAT) AS summa_zadol,

        'B1B' AS shablon
    FROM [CL_PORTFOLIO].[dbo].[AQR2025_B1B_2024_Q4] dd
    LEFT JOIN [personal_tables].[dbo].[RA_NST_segment_AQR2025_B1B] sd  ON dd.loan_id_kr = sd.loan_id_kr -- есть скрипт ниже закомментированный
    WHERE dd.is_del = '0'
),
ALL_DATA AS (
    SELECT * FROM B1A
    UNION ALL
    SELECT * FROM B1B
),
AGG AS (
    SELECT 
        segment_afr,
        stage_b_new,
        SUM(ISNULL(offbal,0)) AS offbal_total,
        SUM(ISNULL(ead,0)) AS ead_total
    FROM ALL_DATA
    GROUP BY segment_afr, stage_b_new
)
SELECT d.shablon,
    d.loan_id_kr,
	d.portfolio,
    d.stage_b,
	d.ccf,
    d.ltv,
    d.lgd,
    d.pd_c12,
    d.pd_cl,
    d.pd_ol,
    d.offbal,
    d.ead,
    d.provisions,
	d.segment_afr,-- по НСТ
    d.summa_zadol,-- по НСТ
    d.stage_b_new, -- по НСТ
    d.ccf_new, -- по НСТ
    d.lgd_new,-- по НСТ
    d.pd_c12_new,-- по НСТ
    d.pd_cl_new,-- по НСТ
    d.pd_ol_new,  -- по НСТ
    cast(ISNULL(d.ccf_new * d.offbal / NULLIF(a.offbal_total, 0), 0) as float) AS ccf_sred,
    cast(ISNULL(d.lgd_new * d.ead / NULLIF(a.ead_total, 0), 0) as float) AS lgd_sred,
    cast(ISNULL(d.pd_c12_new * d.ead / NULLIF(a.ead_total, 0), 0) as float)AS pd_c12_sred,
    cast(ISNULL(d.pd_cl_new * d.ead / NULLIF(a.ead_total, 0), 0) as float)AS pd_cl_sred
	
FROM ALL_DATA d
LEFT JOIN AGG a 
    ON a.segment_afr = d.segment_afr 
   AND a.stage_b_new = d.stage_b_new;



   /*
   --скрипт [personal_tables].[dbo].[RA_NST_segment_AQR2025] 
   --B1A
      select n.*
             , coalesce(cast(ead as float), 0) as ead_n
             , coalesce(cast(od as float), 0)
                  + coalesce(cast(od_del as float), 0)
                  + coalesce(cast(interest as float), 0)
                  + coalesce(cast(interest_del as float), 0)
                  + coalesce(cast(disc_prem as float), 0)
                  as amount
             , case when stage_b = '4' then '3'
			     when stage_b = '1111111111111' then '1'
			  else stage_b end stage
             , case 
                 when ENTITY = 'EUB1' then 'DISASS'  
	             when LSBOO = 1 then 'RELATE'
			    -- when DEBTOR_TYPE=1 then 'CORGOV' -- no such cpty
				 when coalesce(cast(f_inv as float), 0)=1 then 'CORINV'

				       when a.bin is not  null then 'Individual loans'
                 when 
                    sum(coalesce(cast(od as float), 0)
                    + coalesce(cast(od_del as float), 0)
                    + coalesce(cast(interest as float), 0)
                    + coalesce(cast(interest_del as float), 0)
                    + coalesce(cast(correction as float), 0)
                    + coalesce(cast(disc_prem as float), 0)
                    + coalesce(cast(penalty as float), 0)) over (partition by iin_bin)  
                    >=   461235157000* 0.002 then 'Individual loans'  -- сумма СК на 01.01.25 каждый  год меняется согласно отчетной датед

				 when (DEBTOR_TYPE=1 or (DEBTOR_TYPE=0 and DEBTOR_SE=1)) and ENT_TYPE in (1,2,3) and LOAN_OBJ in (1,2,3) and LOAN_PURP in (1,2,3,4,5,8) then 'COREST'         
                	
		        /* when coalesce(cast(debtor_type as float), 0) = 0  
                    and coalesce(cast(ead as float), 0) > 200000000 then 'RETLAR'  /*--  в шаблоне нст убрали данную сегментацию*/*/
     
                  when coalesce(cast(ent_type as float), 0) = 1 then 'CORLAR'
                  when coalesce(cast(ent_type as float), 0) = 2 then 'CORMED'  
                  when coalesce(cast(ent_type as float), 0) = 3 then 'RETSML'  


                  when coalesce(cast(debtor_type as float), 0) = 0
                    and coalesce(cast(ead as float), 0) <= 200000000 
                    and coalesce(cast(debtor_se as float), 0) = 0
                --    and coalesce(cast(collateral as float), 0) = 1 
                    and portfolio in ('Mortgage') then 'RETEST' 
      
        
                            
                  when coalesce(cast(debtor_type as float), 0) = 0
                    and coalesce(cast(ead as float), 0) <= 200000000 
                    and coalesce(cast(debtor_se as float), 0) = 0
                    and coalesce(cast(collateral as float), 0) = 1 then 'RETCAR' 

				when coalesce(cast(debtor_type as float), 0) = 0
                    and coalesce(cast(ead as float), 0) <= 200000000 
                    and coalesce(cast(debtor_se as float), 0) = 0
                    and coalesce(cast(collateral as float), 0) = 0 then 'RETCON' 
                      
                    
                  else 'X'
                  end as segment_afr
            from  [CL_PORTFOLIO].[dbo].AQR2025_B1A_2024_Q4 n
			left join [personal_tables].[dbo].RA_NST_B2A_AQR2025_11082025 a on a.bin=n.IIN_BIN
			where is_del='0'
          -- where  stage_b!='1111111111111' 
   ) f

   select f.* ,segment_afr from [CL_PORTFOLIO].[dbo].AQR2025_B1A_2024_Q4 f
   left join [personal_tables].[dbo].RA_NST_segment_AQR2025 g on f.loan_id_kr=g.loan_id_kr --данные по B2A
   where f.is_del='0'




      --скрипт [personal_tables].[dbo].[RA_NST_segment_AQR2025_B1B]

   --B1B


      select n.*
             , coalesce(cast(ead as float), 0) as ead_n
             , coalesce(cast(correction as float), 0)
            + coalesce(cast(penalty as float), 0)
                  + coalesce(cast(disc_prem as float), 0)
                  as amount
             , case when stage_b = '4' then '3'
			     when stage_b = '1111111111111' then '1'
			  else stage_b end stage
             , case 
                 when ENTITY = 'EUB1' then 'DISASS'  
	             when LSBOO = 1 then 'RELATE'
			    -- when DEBTOR_TYPE=1 then 'CORGOV' -- no such cpty
				 when coalesce(cast(f_inv as float), 0)=1 then 'CORINV'

				       when a.bin is not  null then 'Individual loans'
                 when 
                    sum(coalesce(cast(correction as float), 0)
                    + coalesce(cast(disc_prem as float), 0)
                    + coalesce(cast(penalty as float), 0)) over (partition by iin_bin)  
                    >=  461235157000* 0.002 then 'Individual loans' -- сумма СК на 01.01.25 каждый  год меняется согласно отчетной дате

				 when (DEBTOR_TYPE=1 or (DEBTOR_TYPE=0 and DEBTOR_SE=1)) and ENT_TYPE in (1,2,3) and LOAN_OBJ in (1,2,3) and LOAN_PURP in (1,2,3,4,5,8) then 'COREST'         
                	
		        /* when coalesce(cast(debtor_type as float), 0) = 0  
                    and coalesce(cast(ead as float), 0) > 200000000 then 'RETLAR'  /*--  в шаблоне нст убрали данную сегментацию*/*/
     
                  when coalesce(cast(ent_type as float), 0) = 1 then 'CORLAR'
                  when coalesce(cast(ent_type as float), 0) = 2 then 'CORMED'  
                  when coalesce(cast(ent_type as float), 0) = 3 then 'RETSML'  


                  when coalesce(cast(debtor_type as float), 0) = 0
                    and coalesce(cast(ead as float), 0) <= 200000000 
                    and coalesce(cast(debtor_se as float), 0) = 0
                --    and coalesce(cast(collateral as float), 0) = 1 
                    and portfolio in ('Mortgage') then 'RETEST' 
      
        
                            
                  when coalesce(cast(debtor_type as float), 0) = 0
                    and coalesce(cast(ead as float), 0) <= 200000000 
                    and coalesce(cast(debtor_se as float), 0) = 0
                    and coalesce(cast(collateral as float), 0) = 1 then 'RETCAR' 

				when coalesce(cast(debtor_type as float), 0) = 0
                    and coalesce(cast(ead as float), 0) <= 200000000 
                    and coalesce(cast(debtor_se as float), 0) = 0
                    and coalesce(cast(collateral as float), 0) = 0 then 'RETCON' 
                      
                    
                  else 'X'
                  end as segment_afr
            from  [CL_PORTFOLIO].[dbo].AQR2025_B1B_2024_Q4 n
			left join [personal_tables].[dbo].RA_NST_B2A_AQR2025_11082025 a on a.bin=n.IIN_BIN -- B2A
			where is_del='0'
*/