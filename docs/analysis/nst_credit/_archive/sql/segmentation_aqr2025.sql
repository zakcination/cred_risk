-- Источник: рабочий скрипт AQR-2025 (сегментация / расчёт метрик).
-- Сохранён как есть для истории; замечания и предложения — в SQL_REVIEW.md.
-- Имена таблиц и схем — рабочие; данных банка в репозитории нет.


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
                    >=   461235157000* 0.002 then 'Individual loans'  -- сумма СК на 01.01.25 каждый  год меняется согласно отчетной дате

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
			left join [personal_tables].[dbo].RA_NST_B2A_AQR2025_11082025 a on a.bin=n.IIN_BIN --загрузить данные B2A инд займы
			where is_del='0'
          -- where  stage_b!='1111111111111' 
    ;




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
