-- Tests des contenus de formation (droits, retrait, ordre, publication). Base jetable. Données fictives.
\set ON_ERROR_STOP 1
\pset footer off
begin;
\o /dev/null
create schema t;
create table t.res(n serial, nom text, ok boolean, detail text);
create table t.who(k text primary key, uid uuid);
insert into t.who select k, ('a0000000-0000-0000-0000-00000000000'||i)::uuid from (values
 ('ifap_admin',1),('ifap_formateur',2),('col_admin',3),('col_formateur',4),('apprenant',5),('en_attente',6),('annule',7),('catalogue',8),('autre_apprenant',9)) v(k,i);
create function t.id(p text, i int) returns uuid language sql immutable as $$ select (p||'0000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid $$;
create function t.chemin(c int, f int) returns text language sql immutable as $$ select t.id('3',c)::text||'/'||t.id('f',f)::text||'.pdf' $$;
insert into public.organizations(id,name,kind) values (t.id('1',1),'T IFAP','ifap'),(t.id('1',2),'T Commune','collectivite'),(t.id('1',3),'T Autre','collectivite');
insert into public.organization_members(organization_id,user_id,role)
select t.id('1',o), w.uid, r::public.member_role from (values ('ifap_admin',1,'org_admin'),('ifap_formateur',1,'trainer'),('col_admin',2,'org_admin'),
 ('col_formateur',2,'trainer'),('apprenant',2,'learner'),('en_attente',2,'learner'),('annule',2,'learner'),('catalogue',3,'org_admin'),('autre_apprenant',2,'learner')) v(k,o,r) join t.who w using(k);
insert into public.learners(id,organization_id,user_id,first_name,last_name)
select t.id('2',i), t.id('1',2), (select uid from t.who where k=who), 'Test', who from (values (1,'apprenant'),(2,'en_attente'),(3,'annule')) v(i,who);
-- 1 IFAP catalogue déployée ; 2 IFAP repassée en brouillon ; 3 IFAP au déploiement archivé ; 4 formation de la commune
insert into public.courses(id,owner_organization_id,title,visibility,status)
select t.id('3',i), t.id('1',case when i=4 then 2 else 1 end), 'T cours '||i, case when i=4 then 'private' else 'ifap_catalog' end,'published' from generate_series(1,4) i;
insert into public.course_modules(id,course_id,title,position,content_type) select t.id('4',i),t.id('3',i),'M',1,'module' from generate_series(1,4) i;
insert into public.course_modules(id,course_id,title,position,content_type) values (t.id('4',9),t.id('3',1),'M retiré',2,'module');
insert into public.course_resources(id,course_id,module_id,title,resource_type,storage_path,external_url,is_required) values
 (t.id('b',11),t.id('3',1),t.id('4',1),'PDF','pdf',t.chemin(1,11),null,true),
 (t.id('b',12),t.id('3',1),t.id('4',1),'Retiré','link',null,'https://example.nc',false),
 (t.id('b',91),t.id('3',1),t.id('4',9),'Dans module retiré','link',null,'https://example.nc',false),
 (t.id('b',21),t.id('3',2),t.id('4',2),'Brouillon','link',null,'https://example.nc',true),
 (t.id('b',31),t.id('3',3),t.id('4',3),'Archivé','link',null,'https://example.nc',true),
 (t.id('b',41),t.id('3',4),t.id('4',4),'Commune','link',null,'https://example.nc',true);
insert into public.deployments(id,course_id,target_organization_id,status,enrollment_mode)
select t.id('8',i), t.id('3',i), t.id('1',2), 'available', 'manager' from generate_series(1,3) i;
insert into public.enrollments(id,deployment_id,learner_id,enrollment_mode,status)
select t.id('9',n), t.id('8',d), t.id('2',l), 'manager', s from (values (1,1,1,'enrolled'),(2,1,2,'pending'),(3,1,3,'enrolled'),(21,2,1,'enrolled'),(31,3,1,'enrolled')) v(n,d,l,s);
update public.enrollments set status='cancelled' where id=t.id('9',3);
update public.courses set status='draft', visibility='private' where id=t.id('3',2);
update public.deployments set status='archived' where id=t.id('8',3);
insert into storage.objects(bucket_id,name) values ('course-resources',t.chemin(1,11));
create function t.chk(nom text, qui text, q text, attendu text, conserver boolean default false) returns void language plpgsql as $f$
declare n bigint := 0; err text; code text; res boolean;
begin
  begin
    perform set_config('test.uid', coalesce((select uid::text from t.who where k=qui),''), true);
    if qui = 'anonyme' then set local role anon;
    elsif qui <> 'systeme' then set local role authenticated; end if;
    execute q; get diagnostics n = row_count;
    reset role;
    if not conserver then raise exception using errcode='ZZ999'; end if;
  exception
    when sqlstate 'ZZ999' then null;
    when others then err := sqlerrm; code := sqlstate;
  end;
  reset role; perform set_config('test.uid','',true);
  res := case
    when attendu='ok' then err is null and n>0
    when attendu='refus' then (err is null and n=0) or coalesce(code in ('42501','P0001','23505','23503','23514'),false)
    else err is null and n=attendu::bigint end;
  insert into t.res(nom,ok,detail) values (nom,res,coalesce(code||' '||err, n||' ligne(s)'));
end $f$;
-- état d'une inscription : statut, progression, attestations (total), attestations valides
create function t.etat(nom text, i int, st text, prog numeric, att int, valides int default null) returns void language plpgsql as $f$
declare r record;
begin
  select e.status, e.progress,
    (select count(*) from public.attestations a where a.enrollment_id=e.id) a,
    (select count(*) from public.attestations a where a.enrollment_id=e.id and a.revoked_at is null) v
  into r from public.enrollments e where e.id=t.id('9',i);
  insert into t.res(nom,ok,detail) values (nom, coalesce(r.status=st and r.progress=prog and r.a=att and r.v=coalesce(valides,att),false),
    format('%s %s%% att=%s valides=%s', r.status, r.progress, r.a, r.v));
end $f$;
create function t.lit(res int) returns text language sql as $$ select format('select 1 from public.course_resources where id=%L',t.id('b',res)) $$;
create function t.ajout(res int, c int, md int, url text default 'https://example.nc', chemin text default null) returns text language sql as $$
 select format('insert into public.course_resources(id,course_id,module_id,title,resource_type,external_url,storage_path) values (%L,%L,%L,''N'',%L,%L,%L)',
  t.id('b',res),t.id('3',c),case when md is not null then t.id('4',md) end,case when chemin is null then 'link' else 'pdf' end,url,chemin) $$;
create function t.depot(nom text) returns text language sql as $$ select format('insert into storage.objects(bucket_id,name) values (''course-resources'',%L)',nom) $$;
create function t.fichier(nom text, verbe text default 'select 1 from') returns text language sql as $$ select format('%s storage.objects where bucket_id=''course-resources'' and name=%L',verbe,nom) $$;

-- A. Lecture des contenus
select t.chk('A1 contenu lu par ifap_admin : 1','ifap_admin',t.lit(11),'1');
select t.chk('A2 contenu lu par ifap_formateur : 1','ifap_formateur',t.lit(11),'1');
select t.chk('A3 contenu lu par col_admin : 1','col_admin',t.lit(11),'1');
select t.chk('A4 contenu lu par col_formateur : 1','col_formateur',t.lit(11),'1');
select t.chk('A5 contenu lu par apprenant : 1','apprenant',t.lit(11),'1');
select t.chk('A6 contenu lu par en_attente : 0','en_attente',t.lit(11),'0');
select t.chk('A7 contenu lu par annule : 0','annule',t.lit(11),'0');
select t.chk('A8 contenu lu par catalogue : 0','catalogue',t.lit(11),'0');
select t.chk('A9 contenu lu par anonyme : 0','anonyme',t.lit(11),'0');
select t.chk('A10 le visiteur du catalogue lit la fiche','catalogue',format('select 1 from public.courses where id=%L',t.id('3',1)),'1');
select t.chk('A11 … et le titre du module','catalogue',format('select 1 from public.course_modules where id=%L',t.id('4',1)),'1');
select t.chk('A12 brouillon : le propriétaire lit','ifap_formateur',t.lit(21),'1');
select t.chk('A13 brouillon : le stagiaire ne lit pas','apprenant',t.lit(21),'0');
select t.chk('A14 déploiement archivé : destinataire fermée','col_admin',t.lit(31),'0');
select t.chk('A15 le stagiaire d''un déploiement archivé non plus','apprenant',t.lit(31),'0');
update public.course_resources set retired_at=now() where id=t.id('b',12);
update public.course_modules set retired_at=now() where id=t.id('4',9);
select t.chk('A16 contenu retiré caché au stagiaire','apprenant',t.lit(12),'0');
select t.chk('A17 contenu retiré visible du gestionnaire','ifap_admin',t.lit(12),'1');
select t.chk('A18 module retiré : ses contenus cachés','apprenant',t.lit(91),'0');
select t.chk('A18b module retiré caché au stagiaire','apprenant',format('select 1 from public.course_modules where id=%L',t.id('4',9)),'0');
select t.chk('A19 module retiré visible du gestionnaire','ifap_admin',format('select 1 from public.course_modules where id=%L',t.id('4',9)),'1');
select t.chk('A19b activité sur un contenu retiré refusée','apprenant',format('insert into public.learning_activity_log(enrollment_id,activity_type,resource_id) values (%L,''resource_completed'',%L)',t.id('9',1),t.id('b',12)),'refus');
-- identifiants d'une autre formation
select t.chk('A20 module d''une autre formation','ifap_admin',t.ajout(50,1,4),'refus');
select t.chk('A21 un module ne change pas de formation','ifap_admin',format('update public.course_modules set course_id=%L where id=%L',t.id('3',2),t.id('4',1)),'refus');
select t.chk('A22 un contenu ne change pas de formation','systeme',format('update public.course_resources set course_id=%L, module_id=null where id=%L',t.id('3',2),t.id('b',11)),'refus');
select t.chk('A23 fichier d''une autre formation','ifap_admin',t.ajout(50,1,1,null,t.chemin(4,77)),'refus');
select t.chk('A24 lien http refusé','ifap_admin',t.ajout(50,1,1,'http://example.nc'),'refus');
select t.chk('A25 lien javascript refusé','ifap_admin',t.ajout(50,1,1,'javascript:alert(1)'),'refus');
select t.chk('A26 la commune n''écrit pas chez l''IFAP','col_admin',t.ajout(50,1,1),'refus');
select t.chk('A27 la commune écrit chez elle (admin)','col_admin',t.ajout(51,4,4),'ok');
select t.chk('A28 la commune écrit chez elle (formateur)','col_formateur',t.ajout(52,4,4),'ok');
select t.chk('A29 le stagiaire n''écrit pas','apprenant',t.ajout(53,4,4),'refus');
select t.chk('A29b le formateur IFAP écrit','ifap_formateur',t.ajout(54,1,1),'ok');
-- stockage
select t.chk('A30 dépôt dans sa formation','col_formateur',t.depot(t.chemin(4,60)),'ok');
select t.chk('A31 dépôt dans la formation d''autrui refusé','col_admin',t.depot(t.chemin(1,61)),'refus');
select t.chk('A31b dépôt hors de tout dossier refusé','ifap_admin',t.depot('libre.pdf'),'refus');
select t.chk('A32 le stagiaire lit le fichier','apprenant',t.fichier(t.chemin(1,11)),'1');
select t.chk('A33 le visiteur ne lit pas le fichier','catalogue',t.fichier(t.chemin(1,11)),'0');
select t.chk('A33b demande en attente : pas de fichier','en_attente',t.fichier(t.chemin(1,11)),'0');
select t.chk('A34 fichier référencé non supprimable','ifap_admin',t.fichier(t.chemin(1,11),'delete from'),'refus');
insert into storage.objects(bucket_id,name) values ('course-resources',t.chemin(1,62));
select t.chk('A35 fichier orphelin supprimable par le gestionnaire','ifap_admin',t.fichier(t.chemin(1,62),'delete from'),'ok');
select t.chk('A36 … pas par la commune','col_admin',t.fichier(t.chemin(1,62),'delete from'),'refus');
select t.chk('A37 bucket privé limité aux PDF de 20 Mo','systeme','select 1 from storage.buckets where id=''course-resources'' and not public and file_size_limit=20971520 and allowed_mime_types=array[''application/pdf'']','1');

\o
select n, nom, left(detail,100) detail from t.res where not ok order by n;
select count(*) filter (where ok) as reussis, count(*) filter (where not ok) as echecs from t.res;
rollback;
