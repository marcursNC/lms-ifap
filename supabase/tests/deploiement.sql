-- Tests du déploiement par profil. Base jetable uniquement. Données fictives.
\set ON_ERROR_STOP 1
\pset footer off
begin;
\o /dev/null
create schema t;
create table t.res(n serial, nom text, ok boolean, detail text);
-- profils
create table t.who(k text primary key, uid uuid);
insert into t.who values
 ('ifap_admin','a0000000-0000-0000-0000-000000000001'),('ifap_formateur','a0000000-0000-0000-0000-000000000002'),
 ('col_admin','a0000000-0000-0000-0000-000000000003'),('col_formateur','a0000000-0000-0000-0000-000000000004'),
 ('inscrit','a0000000-0000-0000-0000-000000000005'),('non_inscrit','a0000000-0000-0000-0000-000000000006'),
 ('autre_admin','a0000000-0000-0000-0000-000000000007'),('org_admin_org','a0000000-0000-0000-0000-000000000008');
insert into public.organizations(id,name,kind) values
 ('10000000-0000-0000-0000-000000000001','T IFAP','ifap'),('10000000-0000-0000-0000-000000000002','T Collectivité A','collectivite'),
 ('10000000-0000-0000-0000-000000000003','T Collectivité B','collectivite'),('10000000-0000-0000-0000-000000000004','T Organisme','organisme');
insert into public.organization_members(organization_id,user_id,role)
select ('10000000-0000-0000-0000-00000000000'||o)::uuid, w.uid, r::public.member_role
from (values ('ifap_admin',1,'org_admin'),('ifap_formateur',1,'trainer'),('col_admin',2,'org_admin'),('col_formateur',2,'trainer'),
 ('inscrit',2,'learner'),('non_inscrit',2,'learner'),('autre_admin',3,'org_admin'),('org_admin_org',4,'org_admin')) v(k,o,r) join t.who w using(k);
insert into public.learners(id,organization_id,user_id,first_name,last_name) values
 ('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000005','Test','Inscrit'),
 ('20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000006','Test','NonInscrit'),
 ('20000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000002',null,'Test','Second'),
 ('20000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000003',null,'Test','AutreOrg');
-- formations : 1 privée IFAP, 2 catalogue, 3 brouillon IFAP, 4 privée collectivité A, 5 second catalogue
insert into public.courses(id,owner_organization_id,title,visibility,status) values
 ('30000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','T privée IFAP','private','published'),
 ('30000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','T catalogue','ifap_catalog','published'),
 ('30000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001','T brouillon','private','draft'),
 ('30000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000002','T privée A','private','published'),
 ('30000000-0000-0000-0000-000000000005','10000000-0000-0000-0000-000000000001','T catalogue 2','ifap_catalog','published');
insert into public.course_modules(course_id,title,position,content_type) values ('30000000-0000-0000-0000-000000000001','Module privé',1,'text');
insert into public.evaluations(course_id,title) values ('30000000-0000-0000-0000-000000000001','Évaluation privée');

-- t.chk(nom, profil, requête, attendu, conserver)
-- attendu : 'ok' (au moins une ligne), 'refus' (erreur d'autorisation ou de règle, ou zéro ligne), ou un nombre de lignes exact.
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
  reset role;
  res := case
    when attendu='ok' then err is null and n>0
    when attendu='refus' then (err is null and n=0) or coalesce(code in ('42501','P0001','23505'),false)
    else err is null and n=attendu::bigint end;
  insert into t.res(nom,ok,detail) values (nom,res,coalesce(code||' '||err, n||' ligne(s)'));
end $f$;

-- raccourcis
create function t.dep(course int, org int, mode text default 'manager') returns text language sql as $$
 select format('insert into public.deployments(course_id,target_organization_id,status,enrollment_mode) values (%L,%L,''available'',%L)',
  '30000000-0000-0000-0000-00000000000'||course,'10000000-0000-0000-0000-00000000000'||org,mode) $$;
create function t.maj(course int, org int, set_ text) returns text language sql as $$
 select format('update public.deployments set %s where course_id=%L and target_organization_id=%L',set_,
  '30000000-0000-0000-0000-00000000000'||course,'10000000-0000-0000-0000-00000000000'||org) $$;
create function t.voir(course int, tab text default 'courses') returns text language sql as $$
 select format('select 1 from public.%I where %I=%L',tab,case when tab='courses' then 'id' else 'course_id' end,'30000000-0000-0000-0000-00000000000'||course) $$;
create function t.inscrire(course int, learner int, mode text default 'manager') returns text language sql as $$
 select format('insert into public.enrollments(deployment_id,learner_id,enrollment_mode,status) select id,%L,%L,''enrolled'' from public.deployments where course_id=%L and target_organization_id=''10000000-0000-0000-0000-000000000002''',
  '20000000-0000-0000-0000-00000000000'||learner,mode,'30000000-0000-0000-0000-00000000000'||course) $$;

-- Liste des clients
select t.chk('liste : admin IFAP voit les clients','ifap_admin','select * from public.list_deployable_organizations() where name like ''T %''','3');
select t.chk('liste : formateur IFAP vide','ifap_formateur','select * from public.list_deployable_organizations()','0');
select t.chk('liste : admin collectivité vide','col_admin','select * from public.list_deployable_organizations()','0');
select t.chk('liste : anonyme refusé','anonyme','select * from public.list_deployable_organizations()','refus');
select t.chk('organisations : admin IFAP ne lit toujours que la sienne','ifap_admin','select * from public.organizations','1');

-- Qui déploie : refus
select t.chk('formateur IFAP ne déploie pas','ifap_formateur',t.dep(2,2),'refus');
select t.chk('formateur collectivité ne déploie pas','col_formateur',t.dep(2,2),'refus');
select t.chk('apprenant ne déploie pas','inscrit',t.dep(2,2),'refus');
select t.chk('anonyme ne déploie pas','anonyme',t.dep(2,2),'refus');
select t.chk('collectivité ne se déploie pas une formation privée IFAP','col_admin',t.dep(1,2),'refus');
select t.chk('collectivité ne déploie pas chez une autre','col_admin',t.dep(2,3),'refus');
select t.chk('collectivité ne sort pas sa formation','col_admin',t.dep(4,3),'refus');
select t.chk('IFAP ne déploie pas la formation d''une collectivité','ifap_admin',t.dep(4,3),'refus');
select t.chk('brouillon non déployable','ifap_admin',t.dep(3,2),'refus');
select t.chk('privée vers client : pas d''auto-inscription','ifap_admin',t.dep(1,2,'self_service'),'refus');
select t.chk('privée avant déploiement : invisible au client','col_admin',t.voir(1),'0');

-- Qui déploie : accepté
select t.chk('IFAP déploie une privée chez A','ifap_admin',t.dep(1,2),'ok',true);
select t.chk('IFAP déploie vers un organisme','ifap_admin',t.dep(2,4),'ok');
select t.chk('collectivité prend au catalogue (auto-inscription)','col_admin',t.dep(2,2,'self_service'),'ok',true);
select t.chk('collectivité déploie sa formation chez elle','col_admin',t.dep(4,2),'ok');
select t.chk('origine IFAP fixée par la base','systeme','select 1 from public.deployments where course_id=''30000000-0000-0000-0000-000000000001'' and initiated_by_organization_id=''10000000-0000-0000-0000-000000000001''','1');
select t.chk('origine collectivité fixée par la base','systeme','select 1 from public.deployments where course_id=''30000000-0000-0000-0000-000000000002'' and initiated_by_organization_id=''10000000-0000-0000-0000-000000000002''','1');
select t.chk('origine non falsifiable à la création','col_admin','insert into public.deployments(course_id,target_organization_id,initiated_by_organization_id) values (''30000000-0000-0000-0000-000000000005'',''10000000-0000-0000-0000-000000000002'',''10000000-0000-0000-0000-000000000001'') returning 1/(initiated_by_organization_id=target_organization_id)::int','ok');
select t.chk('pas de doublon','ifap_admin',t.dep(1,2),'refus');
select t.chk('événement de déploiement écrit','systeme','select 1 from public.event_outbox where event_type=''deployment.created''','2');
select t.chk('IFAP voit son déploiement client','ifap_admin',t.voir(1,'deployments'),'1');
select t.chk('autre collectivité ne le voit pas','autre_admin',t.voir(1,'deployments'),'0');

-- Inscriptions
select t.chk('IFAP n''inscrit pas chez le client','ifap_admin',t.inscrire(1,1),'refus');
select t.chk('admin client inscrit sur formation privée','col_admin',t.inscrire(1,1),'ok',true);
select t.chk('un seul événement par inscription','systeme','select 1 from public.event_outbox where event_type=''enrollment.created''','1');
select t.chk('apprenant d''une autre organisation refusé','col_admin',t.inscrire(1,4),'refus');
select t.chk('auto-inscription catalogue','non_inscrit',t.inscrire(2,2,'self_service'),'ok');
select t.chk('IFAP ne lit pas les inscriptions du client','ifap_admin','select 1 from public.enrollments','0');
select t.chk('IFAP ne lit pas les apprenants du client','ifap_admin','select 1 from public.learners','0');

-- Visibilité de la formation privée
select t.chk('admin client voit','col_admin',t.voir(1),'1');
select t.chk('formateur client voit','col_formateur',t.voir(1),'1');
select t.chk('inscrit voit','inscrit',t.voir(1),'1');
select t.chk('inscrit voit les modules','inscrit',t.voir(1,'course_modules'),'1');
select t.chk('inscrit voit l''évaluation','inscrit',t.voir(1,'evaluations'),'1');
select t.chk('non inscrit ne voit pas','non_inscrit',t.voir(1),'0');
select t.chk('non inscrit : ni modules','non_inscrit',t.voir(1,'course_modules'),'0');
select t.chk('non inscrit : ni évaluation','non_inscrit',t.voir(1,'evaluations'),'0');
select t.chk('autre collectivité ne voit pas','autre_admin',t.voir(1),'0');
select t.chk('anonyme ne voit pas','anonyme',t.voir(1),'0');
select t.chk('client ne modifie pas la formation','col_admin','update public.courses set title=''x'' where id=''30000000-0000-0000-0000-000000000001''','refus');
select t.chk('inscription en attente : pas d''accès','systeme','update public.enrollments set status=''pending''','ok',true);
select t.chk('… invisible','inscrit',t.voir(1),'0');
select t.chk('inscription annulée','systeme','update public.enrollments set status=''cancelled''','ok',true);
select t.chk('… invisible','inscrit',t.voir(1),'0');
select t.chk('inscription rétablie','systeme','update public.enrollments set status=''enrolled''','ok',true);

-- Cycle de vie
select t.chk('client ne modifie pas l''envoi IFAP','col_admin',t.maj(1,2,'status=''archived'''),'refus');
select t.chk('IFAP ne modifie pas la prise du client','ifap_admin',t.maj(2,2,'status=''archived'''),'refus');
select t.chk('formateur IFAP ne modifie pas','ifap_formateur',t.maj(1,2,'status=''closed'''),'refus');
select t.chk('formation non modifiable','ifap_admin',t.maj(1,2,'course_id=''30000000-0000-0000-0000-000000000005'''),'refus');
select t.chk('destinataire non modifiable','ifap_admin',t.maj(1,2,'target_organization_id=''10000000-0000-0000-0000-000000000003'''),'refus');
select t.chk('origine non modifiable','ifap_admin',t.maj(1,2,'initiated_by_organization_id=''10000000-0000-0000-0000-000000000002'''),'refus');
select t.chk('pas d''auto-inscription ajoutée sur privée','ifap_admin',t.maj(1,2,'enrollment_mode=''self_service'''),'refus');
select t.chk('suppression impossible (IFAP)','ifap_admin','delete from public.deployments','refus');
select t.chk('suppression impossible (client)','col_admin','delete from public.deployments','refus');
select t.chk('IFAP clôt','ifap_admin',t.maj(1,2,'status=''closed'''),'ok',true);
select t.chk('clos : accès maintenu','inscrit',t.voir(1),'1');
select t.chk('clos : plus de nouvelle inscription','col_admin',t.inscrire(1,3),'refus');
select t.chk('déplacement d''inscription vers un clos refusé','col_admin','update public.enrollments set deployment_id=(select id from public.deployments where course_id=''30000000-0000-0000-0000-000000000001''), learner_id=''20000000-0000-0000-0000-000000000003''','refus');
select t.chk('IFAP archive','ifap_admin',t.maj(1,2,'status=''archived'''),'ok',true);
select t.chk('archivé : inscrit coupé','inscrit',t.voir(1),'0');
select t.chk('archivé : admin client coupé','col_admin',t.voir(1),'0');
select t.chk('archivé : client ne réactive pas','col_admin',t.maj(1,2,'status=''available'''),'refus');
select t.chk('IFAP réactive','ifap_admin',t.maj(1,2,'status=''available'''),'ok',true);
select t.chk('inscription conservée','systeme','select 1 from public.enrollments','1');

-- Brouillon et retrait du catalogue
select t.chk('retour en brouillon','systeme','update public.courses set status=''draft'' where id=''30000000-0000-0000-0000-000000000001''','ok',true);
select t.chk('brouillon : accès coupé','inscrit',t.voir(1),'0');
select t.chk('brouillon : archivage toujours possible','ifap_admin',t.maj(1,2,'status=''archived'''),'ok',true);
select t.chk('brouillon : réactivation refusée','ifap_admin',t.maj(1,2,'status=''available'''),'refus');
select t.chk('retrait du catalogue','systeme','update public.courses set visibility=''private'' where id=''30000000-0000-0000-0000-000000000002''','ok',true);
select t.chk('déploiement existant : admin client voit','col_admin',t.voir(2),'1');
select t.chk('déploiement existant : autre collectivité non','autre_admin',t.voir(2),'0');
select t.chk('repassée privée : auto-inscription refusée','non_inscrit',t.inscrire(2,2,'self_service'),'refus');
select t.chk('repassée privée : le client peut archiver','col_admin',t.maj(2,2,'status=''archived'''),'ok',true);
select t.chk('repassée privée : le client ne réactive pas','col_admin',t.maj(2,2,'status=''available'''),'refus');
select t.chk('achèvement : attestation créée sans erreur','systeme','update public.enrollments set progress=100, status=''completed'', completed_at=now()','ok',true);
select t.chk('un événement d''attestation','systeme','select 1 from public.event_outbox where event_type=''certificate.issued''','1');

-- Administrateur plateforme
select t.chk('rôle plateforme (fictif)','systeme','insert into public.organization_members(organization_id,user_id,role) values (''10000000-0000-0000-0000-000000000004'',''a0000000-0000-0000-0000-000000000009'',''platform_admin'')','ok',true);
insert into t.who values ('plateforme','a0000000-0000-0000-0000-000000000009');
select t.chk('plateforme : déploie une privée chez B','plateforme',t.dep(1,3),'refus');
select t.chk('formation republiée','systeme','update public.courses set status=''published'' where id=''30000000-0000-0000-0000-000000000001''','ok',true);
select t.chk('plateforme : déploie une privée publiée chez B','plateforme',t.dep(1,3),'ok');

\o
select n, case when ok then 'OK ' else 'ECHEC' end as r, nom, left(detail,90) detail from t.res where not ok order by n;
select count(*) filter (where ok) as reussis, count(*) filter (where not ok) as echecs from t.res;
rollback;
