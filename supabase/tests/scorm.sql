-- Tests des modules SCORM (paquets, stockage, tickets, résultats). Base jetable. Données fictives.
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
select t.id('2',i), t.id('1',2), (select uid from t.who where k=who), 'Prénom', who
from (values (1,'apprenant'),(2,'en_attente'),(3,'annule'),(4,'autre_apprenant')) v(i,who);
-- 1 IFAP déployée ; 3 IFAP au déploiement archivé ; 4 formation de la commune ; 6 IFAP avec seuil
insert into public.courses(id,owner_organization_id,title,visibility,status)
select t.id('3',i), t.id('1',case when i=4 then 2 else 1 end), 'T cours '||i, case when i=4 then 'private' else 'ifap_catalog' end,'published' from unnest(array[1,3,4,6]) i;
insert into public.course_modules(id,course_id,title,position,content_type) select t.id('4',i),t.id('3',i),'M',1,'module' from unnest(array[1,3,4,6]) i;
insert into public.course_modules(id,course_id,title,position,content_type) values (t.id('4',12),t.id('3',1),'M2',2,'module');
insert into public.deployments(id,course_id,target_organization_id,status,enrollment_mode)
select t.id('8',i), t.id('3',i), t.id('1',2), 'available', 'manager' from unnest(array[1,3,6]) i;
insert into public.enrollments(id,deployment_id,learner_id,enrollment_mode,status)
select t.id('9',n), t.id('8',d), t.id('2',l), 'manager', s
from (values (1,1,1,'enrolled'),(2,1,2,'pending'),(3,1,3,'enrolled'),(4,1,4,'enrolled'),(31,3,1,'enrolled'),(61,6,1,'enrolled'),(62,6,4,'enrolled')) v(n,d,l,s);
update public.enrollments set status='cancelled' where id=t.id('9',3);

create function t.chk(nom text, qui text, q text, attendu text, conserver boolean default false) returns void language plpgsql as $f$
declare n bigint := 0; err text; code text; res boolean;
begin
  begin
    perform set_config('test.uid', coalesce((select uid::text from t.who where k=qui),''), true);
    if qui = 'anonyme' then set local role anon;
    elsif qui = 'service' then set local role service_role;
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

create function t.v(k text) returns text language sql stable as $$ select coalesce(nullif(current_setting('t.'||k, true),''),'00000000-0000-0000-0000-000000000000') $$;
create function t.reg(k text, c int, md int, mastery numeric default null, files int default 2, bytes bigint default 1000, launch text default 'index.html') returns text language sql as $$
 select format('select set_config(%L, public.scorm_register_package(%L,%L,''Module'',%L,%L,%s,%s)::text, false)','t.'||k,
  t.id('3',c), case when md is not null then t.id('4',md) end, launch, mastery, files, bytes) $$;
create function t.chemin(k text, c int, f text) returns text language sql stable as $$ select t.id('3',c)::text||'/'||t.v(k)||'/'||f $$;
create function t.depot(nom text) returns text language sql as $$ select format('insert into storage.objects(bucket_id,name) values (''scorm-packages'',%L)',nom) $$;
create function t.fichier(nom text, verbe text default 'select 1 from') returns text language sql as $$ select format('%s storage.objects where bucket_id=''scorm-packages'' and name=%L',verbe,nom) $$;
create function t.fin(k text, rk text) returns text language sql stable as $$ select format('select set_config(%L, public.scorm_finalize_package(%L)::text, false)','t.'||rk,t.v(k)) $$;
create function t.abandon(k text) returns text language sql stable as $$ select format('select public.scorm_discard_package(%L)',t.v(k)) $$;
create function t.ouvrir(rk text, e int default null, tk text default 'tk') returns text language sql stable as $$
 select format('select set_config(%L, public.scorm_open(%L,%L)->>''token'', false)','t.'||tk,t.v(rk),case when e is not null then t.id('9',e) end) $$;
create function t.resoudre(tk text, k text, c int) returns text language sql stable as $$
 select format('select 1 where public.scorm_resolve_ticket(%L)=%L',t.v(tk),t.id('3',c)::text||'/'||t.v(k)) $$;
create function t.save(e int, k text, d text, s int default 1) returns text language sql stable as $$
 select format('select public.scorm_save(%L,%L,%L,%L::jsonb)',t.id('9',e),t.v(k),t.id('d',s),d) $$;
create function t.tentative(e int, cond text) returns text language sql as $$
 select format('select 1 from public.scorm_attempts where enrollment_id=%L and %s',t.id('9',e),cond) $$;
create function t.traces(e int, typ text) returns text language sql as $$
 select format('select 1 from public.learning_activity_log where enrollment_id=%L and activity_type=%L',t.id('9',e),typ) $$;

-- Paquets
select t.chk('S1 la commune n''importe pas chez elle (domaine non séparé)','col_admin',t.reg('x',4,4),'refus');
select t.chk('S2 la commune n''importe pas chez l''IFAP','col_admin',t.reg('x',1,1),'refus');
select t.chk('S3 le stagiaire n''importe pas','apprenant',t.reg('x',1,1),'refus');
select t.chk('S4 anonyme non plus','anonyme',t.reg('x',1,1),'refus');
select t.chk('S4b module d''une autre formation','ifap_admin',t.reg('x',1,4),'refus');
select t.chk('S4c démarrage hors du paquet','ifap_admin',t.reg('x',1,1,null,2,1000,'../a.html'),'refus');
select t.chk('S4d démarrage absolu','ifap_admin',t.reg('x',1,1,null,2,1000,'/a.html'),'refus');
select t.chk('S4e trop de fichiers','ifap_admin',t.reg('x',1,1,null,1001),'refus');
select t.chk('S4f paquet trop lourd','ifap_admin',t.reg('x',1,1,null,2,157286401),'refus');
select t.chk('S5 le formateur IFAP importe','ifap_formateur',t.reg('p1',1,1),'ok',true);
-- Stockage
select t.chk('S6 dépôt du démarrage','ifap_admin',t.depot(t.chemin('p1',1,'index.html')),'ok',true);
select t.chk('S7 la commune ne dépose pas','col_admin',t.depot(t.chemin('p1',1,'x.js')),'refus');
select t.chk('S7b le stagiaire non plus','apprenant',t.depot(t.chemin('p1',1,'x.js')),'refus');
select t.chk('S8 dépôt hors paquet refusé','ifap_admin',t.depot(t.id('3',1)::text||'/libre.js'),'refus');
select t.chk('S8b dépôt remontant refusé','ifap_admin',t.depot(t.chemin('p1',1,'../x.js')),'refus');
select t.chk('S13 finalisation incomplète refusée','ifap_admin',t.fin('p1','r1'),'refus');
select t.chk('S13b aucun contenu visible','systeme',format('select 1 from public.course_resources where course_id=%L',t.id('3',1)),'0');
select t.chk('S6b second fichier','ifap_admin',t.depot(t.chemin('p1',1,'assets/image é.webp')),'ok',true);
select t.chk('S14 la commune ne finalise pas','col_admin',t.fin('p1','r1'),'refus');
select t.chk('S15 finalisation complète','ifap_admin',t.fin('p1','r1'),'ok',true);
select t.chk('S15b une ressource scorm obligatoire','apprenant',format('select 1 from public.course_resources where id=%L and resource_type=''scorm'' and is_required and launch_path=''index.html''',t.v('r1')),'1');
select t.chk('S15c double finalisation refusée','ifap_admin',t.fin('p1','r9'),'refus');
select t.chk('S9 paquet prêt : plus de dépôt','ifap_admin',t.depot(t.chemin('p1',1,'ajout.js')),'refus');
select t.chk('S9b paquet prêt : fichiers non supprimables','ifap_admin',t.fichier(t.chemin('p1',1,'index.html'),'delete from'),'refus');
select t.chk('S10 le stagiaire ne lit pas le stockage','apprenant',t.fichier(t.chemin('p1',1,'index.html')),'0');
select t.chk('S11 le visiteur non plus','catalogue',t.fichier(t.chemin('p1',1,'index.html')),'0');
select t.chk('S12 le gestionnaire lit','ifap_formateur',t.fichier(t.chemin('p1',1,'index.html')),'1');
select t.chk('S12b le stagiaire ne lit pas la table des paquets','apprenant','select 1 from public.scorm_packages','0');
select t.chk('S12c le visiteur non plus','catalogue','select 1 from public.scorm_packages','0');
select t.chk('S12d le gestionnaire la lit','ifap_admin','select 1 from public.scorm_packages','1');
select t.chk('S16 écriture directe d''un paquet refusée','ifap_admin',format('insert into public.scorm_packages(course_id,title,storage_path,launch_path) values (%L,''X'',''x'',''i.html'')',t.id('3',1)),'refus');
select t.chk('S17 modification directe refusée','ifap_admin','update public.scorm_packages set mastery_score=0','refus');
select t.chk('S18 le stagiaire n''écrit pas sa tentative','apprenant',format('insert into public.scorm_attempts(scorm_package_id,enrollment_id,status,lesson_status) values (%L,%L,''completed'',''passed'')',t.v('p1'),t.id('9',1)),'refus');
select t.chk('S18b l''admin de la collectivité non plus','col_admin',format('insert into public.scorm_attempts(scorm_package_id,enrollment_id) values (%L,%L)',t.v('p1'),t.id('9',1)),'refus');
-- Abandon
select t.chk('S60 second paquet','ifap_admin',t.reg('p3',1,12),'ok',true);
select t.chk('S60b un fichier','ifap_admin',t.depot(t.chemin('p3',1,'index.html')),'ok',true);
select t.chk('S61 abandon refusé tant qu''il reste des fichiers','ifap_admin',t.abandon('p3'),'refus');
select t.chk('S62 la commune ne supprime pas ces fichiers','col_admin',t.fichier(t.chemin('p3',1,'index.html'),'delete from'),'refus');
select t.chk('S63 le gestionnaire les supprime','ifap_admin',t.fichier(t.chemin('p3',1,'index.html'),'delete from'),'ok',true);
select t.chk('S64 la commune n''abandonne pas','col_admin',t.abandon('p3'),'refus');
select t.chk('S65 abandon','ifap_admin',t.abandon('p3'),'ok',true);
select t.chk('S65b paquet disparu','systeme',format('select 1 from public.scorm_packages where id=%L',t.v('p3')),'0');
select t.chk('S66 un paquet publié ne s''abandonne pas','ifap_admin',t.abandon('p1'),'refus');
select t.chk('S67 SCORM inutilisé : supprimé','ifap_admin',t.reg('p4',1,12,null,1),'ok',true);
select t.chk('S67b dépôt','ifap_admin',t.depot(t.chemin('p4',1,'index.html')),'ok',true);
select t.chk('S67c final','ifap_admin',t.fin('p4','r4'),'ok',true);
select t.chk('S67d retrait','ifap_admin',format('select 1 where public.remove_course_item(''resource'',%L)=''deleted''',t.v('r4')),'ok',true);
select t.chk('S67e ses fichiers deviennent supprimables','ifap_admin',t.fichier(t.chemin('p4',1,'index.html'),'delete from'),'ok',true);
select t.chk('S67f puis le paquet','ifap_admin',t.abandon('p4'),'ok',true);
-- Tickets
select t.chk('S19 aperçu du gestionnaire','ifap_formateur',t.ouvrir('r1',null,'apercu'),'ok',true);
select t.chk('S19b aperçu sans état','ifap_admin',format('select 1 where public.scorm_open(%L)->''state''=''null''::jsonb',t.v('r1')),'1');
select t.chk('S19c pas d''aperçu pour le stagiaire','apprenant',t.ouvrir('r1'),'refus');
select t.chk('S19d ni pour la collectivité destinataire','col_admin',t.ouvrir('r1'),'refus');
select t.chk('S20 le stagiaire inscrit ouvre','apprenant',t.ouvrir('r1',1),'ok',true);
select t.chk('S20b son nom est fourni','apprenant',format('select 1 where public.scorm_open(%L,%L)#>>''{state,student_name}''=''apprenant, Prénom''',t.v('r1'),t.id('9',1)),'1');
select t.chk('S21 demande en attente','en_attente',t.ouvrir('r1',2),'refus');
select t.chk('S22 inscription annulée','annule',t.ouvrir('r1',3),'refus');
select t.chk('S23 inscription d''autrui','autre_apprenant',t.ouvrir('r1',1),'refus');
select t.chk('S23b inscription d''une autre formation','apprenant',t.ouvrir('r1',61),'refus');
select t.chk('S24 anonyme','anonyme',t.ouvrir('r1',1),'refus');
select t.chk('S27 ticket résolu par le lecteur','service',t.resoudre('tk','p1',1),'1');
select t.chk('S28 ticket inconnu','service','select 1 where public.scorm_resolve_ticket(''faux'') is null','1');
select t.chk('S29 appel par un utilisateur refusé','apprenant',t.resoudre('tk','p1',1),'refus');
select t.chk('S29b par anonyme refusé','anonyme',t.resoudre('tk','p1',1),'refus');
select t.chk('S29c le jeton n''est pas stocké en clair','systeme',format('select 1 from app_private.scorm_tickets where token_hash=%L',t.v('tk')),'0');
select t.chk('S29d la table des tickets est fermée','apprenant','select 1 from app_private.scorm_tickets','refus');
select t.chk('S29e durée de 4 heures','systeme','select 1 from app_private.scorm_tickets where expires_at > now()+interval ''4 hours''','0');
update app_private.scorm_tickets set expires_at=now()-interval '1 second';
select t.chk('S30 ticket expiré','service','select 1 where public.scorm_resolve_ticket('''||t.v('tk')||''') is null','1');

-- Résultats
select t.chk('S31 un autre apprenant n''enregistre pas','autre_apprenant',t.save(1,'p1','{"lesson_status":"completed"}'),'refus');
select t.chk('S32 la collectivité non plus','col_admin',t.save(1,'p1','{"lesson_status":"completed"}'),'refus');
select t.chk('S33 l''IFAP non plus','ifap_admin',t.save(1,'p1','{"lesson_status":"completed"}'),'refus');
select t.chk('S34 anonyme non plus','anonyme',t.save(1,'p1','{"lesson_status":"completed"}'),'refus');
select t.chk('S35 paquet d''une autre formation','apprenant',t.save(61,'p1','{"lesson_status":"completed"}'),'refus');
select t.chk('S44 score hors bornes','apprenant',t.save(1,'p1','{"score_raw":101}'),'refus');
select t.chk('S44b score illisible','apprenant',t.save(1,'p1','{"score_raw":"abc"}'),'refus');
select t.chk('S44c statut inconnu','apprenant',t.save(1,'p1','{"lesson_status":"termine"}'),'refus');
select t.chk('S45 reprise trop longue','apprenant',t.save(1,'p1',json_build_object('suspend_data',repeat('a',64001))::text),'refus');
select t.chk('S45b durée négative','apprenant',t.save(1,'p1','{"session_seconds":-5}'),'refus');
select t.chk('S36 en cours','apprenant',t.save(1,'p1','{"lesson_status":"incomplete","lesson_location":"3","suspend_data":"{\"a\":1}"}'),'ok',true);
select t.etat('S36b parcours en cours',1,'in_progress',0,0);
select t.chk('S36c une trace d''ouverture','systeme',t.traces(1,'resource_opened'),'1');
select t.chk('S36d reprise restituée','apprenant',format('select 1 from (select public.scorm_open(%L,%L)->''state'' s) q where s->>''lesson_location''=''3'' and s->>''suspend_data''=''{"a":1}'' and s->>''entry''=''resume''',t.v('r1'),t.id('9',1)),'1');
select t.chk('S43 temps de session','apprenant',t.save(1,'p1','{"session_seconds":60}',1),'ok',true);
select t.chk('S43b même session renvoyée','apprenant',t.save(1,'p1','{"session_seconds":60}',1),'ok',true);
select t.chk('S43c même session prolongée','apprenant',t.save(1,'p1','{"session_seconds":90}',1),'ok',true);
select t.chk('S43d autre session','apprenant',t.save(1,'p1','{"session_seconds":10}',2),'ok',true);
select t.chk('S43e total 100 s','systeme',t.tentative(1,'total_time_seconds=100'),'1');
select t.chk('S43g séance de 30 h acceptée','apprenant',t.save(1,'p1','{"session_seconds":108000}',3),'ok',true);
select t.chk('S43h comptée au plus 24 h','systeme',t.tentative(1,'total_time_seconds=86500'),'1');
select t.chk('S43i durée extrême acceptée','apprenant',t.save(1,'p1','{"session_seconds":35999999}',3),'ok',true);
select t.chk('S43j non recomptée','systeme',t.tentative(1,'total_time_seconds=86500'),'1');
select t.chk('S43f les champs absents sont conservés','systeme',t.tentative(1,'suspend_data=''{"a":1}'' and lesson_status=''incomplete'''),'1');
select t.chk('S46 « Terminer » à la main refusé sur un SCORM','apprenant',format('insert into public.learning_activity_log(enrollment_id,activity_type,resource_id) values (%L,''resource_completed'',%L)',t.id('9',1),t.v('r1')),'refus');
select t.chk('S46b progression à 100 refusée aussi','apprenant',format('insert into public.learning_activity_log(enrollment_id,activity_type,resource_id,progress) values (%L,''resource_opened'',%L,100)',t.id('9',1),t.v('r1')),'refus');
select t.chk('S46c ouverture acceptée','apprenant',format('insert into public.learning_activity_log(enrollment_id,activity_type,resource_id,progress) values (%L,''resource_opened'',%L,0)',t.id('9',1),t.v('r1')),'ok');
select t.chk('S53 un autre apprenant ne lit pas la tentative','autre_apprenant',t.tentative(1,'true'),'0');
select t.chk('S53b le stagiaire lit la sienne','apprenant',t.tentative(1,'true'),'1');
select t.chk('S53c son employeur la lit','col_admin',t.tentative(1,'true'),'1');
select t.chk('S37 terminé','apprenant',t.save(1,'p1','{"lesson_status":"completed","score_raw":40}'),'ok',true);
select t.etat('S52 formation sans séance : terminée et attestée',1,'completed',100,1);
select t.chk('S38 renvoi','apprenant',t.save(1,'p1','{"lesson_status":"completed","score_raw":40}'),'ok',true);
select t.chk('S39 une seule trace d''achèvement','systeme',t.traces(1,'resource_completed'),'1');
select t.chk('S40 un contenu terminé le reste','apprenant',t.save(1,'p1','{"lesson_status":"incomplete","score_raw":0,"lesson_location":"1"}'),'ok',true);
select t.chk('S40b statut et score conservés, position à jour','systeme',t.tentative(1,'lesson_status=''completed'' and score=40 and status=''completed'' and completed_at is not null and cmi_data->>''lesson_location''=''1'''),'1');
-- Seuil
select t.chk('S41a paquet avec seuil','ifap_admin',t.reg('p2',6,6,80,1),'ok',true);
select t.chk('S41b dépôt','ifap_admin',t.depot(t.chemin('p2',6,'index.html')),'ok',true);
select t.chk('S41c final','ifap_admin',t.fin('p2','r2'),'ok',true);
select t.chk('S41 79 sous le seuil','apprenant',t.save(61,'p2','{"lesson_status":"completed","score_raw":79}'),'ok',true);
select t.chk('S41d échec','systeme',t.tentative(61,'lesson_status=''failed'' and completed_at is null'),'1');
select t.etat('S41e non terminé',61,'in_progress',0,0);
select t.chk('S42 80 au seuil','autre_apprenant',t.save(62,'p2','{"lesson_status":"completed","score_raw":80}'),'ok',true);
select t.chk('S42b réussi','systeme',t.tentative(62,'lesson_status=''passed'' and completed_at is not null'),'1');
-- Fermetures
select t.chk('S49 inscription annulée','annule',t.save(3,'p1','{"lesson_status":"completed"}'),'refus');
select t.chk('S50 demande en attente','en_attente',t.save(2,'p1','{"lesson_status":"completed"}'),'refus');
select t.chk('S48 retrait d''un SCORM suivi : retiré','ifap_admin',format('select 1 where public.remove_course_item(''resource'',%L)=''retired''',t.v('r2')),'ok',true);
select t.chk('S48b tentative conservée','systeme',t.tentative(61,'true'),'1');
select t.chk('S48c contenu retiré : plus d''ouverture','apprenant',t.ouvrir('r2',61),'refus');
select t.chk('S48d ni d''enregistrement','apprenant',t.save(61,'p2','{"lesson_status":"incomplete"}'),'refus');
-- tentative sans trace d'activité : le contenu ne doit pas être supprimé
select t.chk('S54a paquet','ifap_admin',t.reg('p5',1,12,null,1),'ok',true);
select t.chk('S54b dépôt','ifap_admin',t.depot(t.chemin('p5',1,'index.html')),'ok',true);
select t.chk('S54c final','ifap_admin',t.fin('p5','r5'),'ok',true);
insert into public.scorm_attempts(scorm_package_id,enrollment_id) values (t.v('p5')::uuid,t.id('9',4));
select t.chk('S54 tentative sans trace : retiré','ifap_admin',format('select 1 where public.remove_course_item(''resource'',%L)=''retired''',t.v('r5')),'ok',true);
select t.chk('S56a paquet','ifap_admin',t.reg('p6',1,12,null,1),'ok',true);
select t.chk('S56b dépôt','ifap_admin',t.depot(t.chemin('p6',1,'index.html')),'ok',true);
select t.chk('S56c final','ifap_admin',t.fin('p6','r6'),'ok',true);
delete from public.learning_activity_log where resource_id in (select id from public.course_resources where module_id=t.id('4',12));
select t.chk('S56 module avec une tentative sans trace : retiré','ifap_admin',format('select 1 where public.remove_course_item(''module'',%L)=''retired''',t.id('4',12)),'ok',true);
select t.chk('S56d tentative conservée','systeme',t.tentative(4,'true'),'1');
select t.chk('S25a ouverture sur un paquet actif','autre_apprenant',t.ouvrir('r1',4),'ok');
update public.deployments set status='archived' where id=t.id('8',1);
select t.chk('S25 déploiement archivé : pas d''ouverture','autre_apprenant',t.ouvrir('r1',4),'refus');
select t.chk('S51 déploiement archivé : pas d''enregistrement','autre_apprenant',t.save(4,'p1','{"lesson_status":"completed"}'),'refus');
select t.chk('S55 bucket privé limité à 50 Mo','systeme','select 1 from storage.buckets where id=''scorm-packages'' and not public and file_size_limit=52428800','1');

\o
select n, nom, left(detail,100) detail from t.res where not ok order by n;
select count(*) filter (where ok) as reussis, count(*) filter (where not ok) as echecs from t.res;
rollback;
