with ns as (select oid,nspname from pg_namespace where nspname in ('public','app_private')),
x as (
 select 'function' k, n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')' o,
   md5(regexp_replace(p.prosrc,'\s+','','g')||p.prosecdef::text||coalesce(array_to_string(p.proconfig,','),'')) h
   from pg_proc p join ns n on n.oid=p.pronamespace where not exists(select 1 from pg_depend d where d.objid=p.oid and d.deptype='e')
 union all select 'policy', schemaname||'.'||tablename||'.'||policyname, md5(permissive||cmd||roles::text||regexp_replace(coalesce(qual,'')||'|'||coalesce(with_check,''),'\s+|public\.','','g')) from pg_policies where schemaname in ('public','storage')
 union all select 'trigger', n.nspname||'.'||c.relname||'.'||t.tgname, md5(regexp_replace(pg_get_triggerdef(t.oid),'public\.','','g')||t.tgenabled::text) from pg_trigger t join pg_class c on c.oid=t.tgrelid join ns n on n.oid=c.relnamespace where not t.tgisinternal
 union all select 'column', c.relname||'.'||a.attname, md5(format_type(a.atttypid,a.atttypmod)||a.attnotnull::text||coalesce(regexp_replace(pg_get_expr(d.adbin,d.adrelid),'public\.|extensions\.','','g'),'')) from pg_attribute a join pg_class c on c.oid=a.attrelid join ns n on n.oid=c.relnamespace left join pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum where a.attnum>0 and not a.attisdropped and c.relkind in ('r','v')
 union all select 'constraint', c.relname||'.'||co.conname, md5(regexp_replace(pg_get_constraintdef(co.oid),'public\.','','g')) from pg_constraint co join pg_class c on c.oid=co.conrelid join ns n on n.oid=c.relnamespace where co.contype<>'n'
 union all select 'index', schemaname||'.'||indexname, md5(regexp_replace(indexdef,'public\.','','g')) from pg_indexes where schemaname in ('public','app_private')
 union all select 'rls', c.relname, c.relrowsecurity::text from pg_class c join ns n on n.oid=c.relnamespace where c.relkind='r'
 union all select 'view', c.relname, md5(regexp_replace(pg_get_viewdef(c.oid),'\s+|public\.','','g')||coalesce(c.reloptions::text,'')) from pg_class c join ns n on n.oid=c.relnamespace where c.relkind='v'
 union all select 'enum', t.typname, md5(string_agg(e.enumlabel,',' order by e.enumsortorder)) from pg_enum e join pg_type t on t.oid=e.enumtypid join ns n on n.oid=t.typnamespace group by t.typname
)
select json_agg(json_build_array(k,o,h) order by k,o) from x;
