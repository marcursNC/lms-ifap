-- Éditeur de formation : droits sur les contenus, stockage des PDF, retrait, ordre et publication.
-- Retour arrière : supabase/rollback/20261127000000_editeur_contenu.sql

-- 1. Colonnes ------------------------------------------------------------------------------------
alter table public.course_modules add column retired_at timestamptz;
alter table public.course_resources
  add column retired_at timestamptz,
  add column position integer not null default 0;
alter table public.course_resources
  add constraint course_resources_https_check check (external_url is null or external_url ~ '^https://'),
  add constraint course_resources_path_check
    check (storage_path is null or split_part(storage_path, '/', 1) = course_id::text);

-- 2. Qui gère, qui lit ---------------------------------------------------------------------------
create function app_private.can_manage_course_content(p_course uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select app_private.is_platform_admin() or exists (
    select 1 from public.courses c
    where c.id = p_course
      and app_private.is_org_member(c.owner_organization_id,
            array['org_admin','trainer','platform_admin']::public.member_role[]));
$$;

create function app_private.can_view_course_content(p_course uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select app_private.can_manage_course_content(p_course) or exists (
    select 1 from public.courses c
    where c.id = p_course and c.status <> 'draft'::public.course_status
      and app_private.can_view_deployed_course(c.id));
$$;

revoke all on function
  app_private.can_manage_course_content(uuid), app_private.can_view_course_content(uuid)
from public, anon, authenticated;
grant execute on function
  app_private.can_manage_course_content(uuid), app_private.can_view_course_content(uuid)
to authenticated;

-- Titres des modules : visibles avec la fiche. Contenus : gestionnaires, destinataires, inscrits.
drop policy modules_select on public.course_modules;
create policy modules_select on public.course_modules for select to authenticated using (
  exists (select 1 from public.courses c where c.id = course_modules.course_id)
  and (course_modules.retired_at is null or app_private.can_manage_course_content(course_modules.course_id)));

drop policy course_resources_select on public.course_resources;
create policy course_resources_select on public.course_resources for select to authenticated using (
  app_private.can_manage_course_content(course_resources.course_id)
  or (course_resources.retired_at is null
      and (course_resources.module_id is null or exists (
            select 1 from public.course_modules m
            where m.id = course_resources.module_id and m.retired_at is null))
      and app_private.can_view_course_content(course_resources.course_id)));

drop policy learning_activity_log_insert_self on public.learning_activity_log;
create policy learning_activity_log_insert_self on public.learning_activity_log
for insert to authenticated with check (
  exists (
    select 1 from public.enrollments e
    join public.learners l on l.id = e.learner_id
    join public.deployments d on d.id = e.deployment_id
    where e.id = learning_activity_log.enrollment_id
      and e.status <> 'cancelled'
      and l.user_id = (select auth.uid())
      and (learning_activity_log.resource_id is null or exists (
            select 1 from public.course_resources r
            where r.id = learning_activity_log.resource_id and r.course_id = d.course_id
              and r.retired_at is null))
      and (learning_activity_log.module_id is null or exists (
            select 1 from public.course_modules cm
            where cm.id = learning_activity_log.module_id and cm.course_id = d.course_id
              and cm.retired_at is null))
  ));

-- 3. Cohérence : un contenu reste dans sa formation ----------------------------------------------
create function app_private.enforce_content_course()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.course_id is distinct from old.course_id then
    raise exception 'Un contenu ne change pas de formation';
  end if;
  if tg_table_name = 'course_resources' then
    if new.module_id is not null and not exists (
         select 1 from public.course_modules m where m.id = new.module_id and m.course_id = new.course_id) then
      raise exception 'Ce module appartient à une autre formation';
    end if;
  end if;
  return new;
end $$;
revoke all on function app_private.enforce_content_course() from public, anon, authenticated;
create trigger course_modules_same_course before insert or update on public.course_modules
  for each row execute function app_private.enforce_content_course();
create trigger course_resources_same_course before insert or update on public.course_resources
  for each row execute function app_private.enforce_content_course();

-- 4. Stockage des PDF ----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('course-resources', 'course-resources', false, 20971520, array['application/pdf'])
on conflict (id) do update set public = false, file_size_limit = 20971520,
  allowed_mime_types = array['application/pdf'];

-- Lecture : le gestionnaire, ou toute personne qui voit le contenu qui référence le fichier.
create policy course_files_select on storage.objects for select to authenticated using (
  bucket_id = 'course-resources' and (
    exists (select 1 from public.courses c
            where c.id::text = split_part(objects.name, '/', 1) and app_private.can_manage_course_content(c.id))
    or exists (select 1 from public.course_resources r where r.storage_path = objects.name)));

-- Pas de politique de mise à jour : un fichier publié ne se remplace pas.
create policy course_files_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'course-resources'
  and exists (select 1 from public.courses c
              where c.id::text = split_part(objects.name, '/', 1) and app_private.can_manage_course_content(c.id)));

create policy course_files_delete on storage.objects for delete to authenticated using (
  bucket_id = 'course-resources'
  and exists (select 1 from public.courses c
              where c.id::text = split_part(objects.name, '/', 1) and app_private.can_manage_course_content(c.id))
  and not exists (select 1 from public.course_resources r where r.storage_path = objects.name));

-- 5. La règle d'achèvement ignore ce qui est retiré (seul changement) ----------------------------
create or replace function app_private.apply_completion(p_enrollment uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  e record;
  n_total integer := 0; n_done integer := 0; n integer; d integer;
  third_party boolean; met boolean; active boolean; new_status text;
begin
  select en.status, en.learner_id, en.started_at, dep.id as deployment_id, dep.status as deployment_status,
         dep.course_id, dep.target_organization_id <> c.owner_organization_id as external
    into e
  from public.enrollments en
  join public.deployments dep on dep.id = en.deployment_id
  join public.courses c on c.id = dep.course_id
  where en.id = p_enrollment
  for update of en;
  if not found or e.status in ('cancelled','completed','pending')
     or e.deployment_status = 'archived'::public.deployment_status then
    return;
  end if;

  -- ressources obligatoires (hors module ou dans un module obligatoire)
  select count(*), count(*) filter (where exists (
           select 1 from public.learning_activity_log a
           where a.enrollment_id = p_enrollment and a.resource_id = r.id and a.activity_type = 'resource_completed'))
    into n, d
  from public.course_resources r
  where r.course_id = e.course_id and r.is_required and r.retired_at is null
    and (r.module_id is null or exists (
          select 1 from public.course_modules m where m.id = r.module_id and m.is_required and m.retired_at is null));
  n_total := n_total + n; n_done := n_done + d;

  -- évaluations obligatoires, toutes
  select count(*), count(*) filter (where exists (
           select 1 from public.evaluation_attempts t
           where t.evaluation_id = ev.id and t.learner_id = e.learner_id and t.passed))
    into n, d
  from public.evaluations ev where ev.course_id = e.course_id and ev.is_required;
  n_total := n_total + n; n_done := n_done + d;

  -- séances où l'inscription est portée ; chez un tiers le seuil ne descend pas sous 80 %
  select count(*), count(*) filter (where exists (
           select 1 from public.attendance a
           where a.session_id = s.id and a.learner_id = e.learner_id and a.present
             and coalesce(a.attendance_percent, 0) >= case when e.external
                   then greatest(coalesce(s.required_attendance_percent, 80), 80)
                   else coalesce(s.required_attendance_percent, 80) end))
    into n, d
  from public.session_enrollments se join public.sessions s on s.id = se.session_id
  where se.enrollment_id = p_enrollment and s.status <> 'cancelled';
  n_total := n_total + n; n_done := n_done + d;

  third_party := e.external and exists (select 1 from public.sessions s where s.deployment_id = e.deployment_id);
  met := n_total > 0 and n_done = n_total;
  active := e.started_at is not null
    or exists (select 1 from public.learning_activity_log a where a.enrollment_id = p_enrollment)
    or exists (select 1 from public.evaluation_attempts t join public.evaluations ev on ev.id = t.evaluation_id
               where t.learner_id = e.learner_id and ev.course_id = e.course_id)
    or exists (select 1 from public.session_enrollments se join public.attendance a on a.session_id = se.session_id
               where se.enrollment_id = p_enrollment and a.learner_id = e.learner_id and a.present);
  if not active and not met then
    return;
  end if;

  new_status := case when not met then 'in_progress'
                     when third_party then 'awaiting_validation'
                     else 'completed' end;
  update public.enrollments set
    status = new_status,
    progress = case when n_total = 0 then 0 else round(n_done::numeric / n_total * 100, 2) end,
    started_at = coalesce(started_at, now()),
    completed_at = case when new_status = 'completed' then now() end
  where id = p_enrollment;
end $$;

-- 6. Modifier une formation recalcule les parcours en cours ---------------------------------------
create function app_private.completion_from_content()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_course uuid := case when tg_op = 'DELETE' then old.course_id else new.course_id end;
begin
  perform app_private.apply_completion(en.id)
  from public.enrollments en
  join public.deployments d on d.id = en.deployment_id
  where d.course_id = v_course;
  return null;
end $$;
create trigger completion_on_resource
  after insert or delete or update of is_required, retired_at, module_id on public.course_resources
  for each row execute function app_private.completion_from_content();
create trigger completion_on_module
  after delete or update of is_required, retired_at on public.course_modules
  for each row execute function app_private.completion_from_content();

-- 7. Retirer sans perdre de trace ------------------------------------------------------------------
-- Une suppression passe uniquement par remove_course_item.
revoke delete, truncate on public.course_modules, public.course_resources from anon, authenticated;

create function public.remove_course_item(p_kind text, p_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare v_course uuid; v_retired timestamptz; v_used boolean;
begin
  if p_kind = 'resource' then
    select course_id, retired_at into v_course, v_retired from public.course_resources where id = p_id for update;
  elsif p_kind = 'module' then
    select course_id, retired_at into v_course, v_retired from public.course_modules where id = p_id for update;
  else
    raise exception 'Type d''élément inconnu';
  end if;
  if v_course is null or not app_private.can_manage_course_content(v_course) then
    raise exception 'Élément introuvable ou action non autorisée' using errcode = '42501';
  end if;
  if v_retired is not null then raise exception 'Cet élément est déjà retiré'; end if;

  if p_kind = 'resource' then
    select exists (select 1 from public.learning_activity_log a where a.resource_id = p_id) into v_used;
    if v_used then
      update public.course_resources set retired_at = now() where id = p_id;
    else
      delete from public.course_resources where id = p_id;
    end if;
  else
    select exists (
      select 1 from public.learning_activity_log a
      where a.module_id = p_id
         or a.resource_id in (select r.id from public.course_resources r where r.module_id = p_id)) into v_used;
    if v_used then
      update public.course_resources set retired_at = now() where module_id = p_id and retired_at is null;
      update public.course_modules set retired_at = now() where id = p_id;
    else
      delete from public.course_resources where module_id = p_id;
      delete from public.course_modules where id = p_id;
    end if;
  end if;
  return case when v_used then 'retired' else 'deleted' end;
end $$;

-- 8. Ordre : position = rang dans la liste reçue --------------------------------------------------
create function public.reorder_course_content(p_course uuid, p_modules uuid[], p_resources uuid[])
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not app_private.can_manage_course_content(p_course) then
    raise exception 'Action non autorisée' using errcode = '42501';
  end if;
  if exists (select 1 from unnest(p_modules) x(id)
             where not exists (select 1 from public.course_modules m where m.id = x.id and m.course_id = p_course))
     or exists (select 1 from unnest(p_resources) x(id)
             where not exists (select 1 from public.course_resources r where r.id = x.id and r.course_id = p_course)) then
    raise exception 'Un élément n''appartient pas à cette formation';
  end if;
  update public.course_modules set position = array_position(p_modules, id)
  where course_id = p_course and id = any (p_modules);
  update public.course_resources set position = array_position(p_resources, id)
  where course_id = p_course and id = any (p_resources);
end $$;

-- 9. Publication : au moins un contenu -----------------------------------------------------------
create function app_private.enforce_publication_content()
returns trigger language plpgsql set search_path = '' as $$
begin
  if current_user in ('anon','authenticated') and new.status = 'published'::public.course_status then
    if tg_op = 'UPDATE' then
      if old.status = 'published'::public.course_status then return new; end if;
    end if;
    if not exists (
         select 1 from public.course_resources r
         where r.course_id = new.id and r.retired_at is null
           and (r.module_id is null or exists (
                 select 1 from public.course_modules m where m.id = r.module_id and m.retired_at is null))) then
      raise exception 'La publication demande au moins un contenu';
    end if;
  end if;
  return new;
end $$;
create trigger courses_publication_content before insert or update of status on public.courses
  for each row execute function app_private.enforce_publication_content();

-- 10. Exécution -----------------------------------------------------------------------------------
revoke all on function app_private.completion_from_content(), app_private.enforce_publication_content()
from public, anon, authenticated;
revoke all on function
  public.remove_course_item(text, uuid), public.reorder_course_content(uuid, uuid[], uuid[])
from public, anon;
grant execute on function
  public.remove_course_item(text, uuid), public.reorder_course_content(uuid, uuid[], uuid[])
to authenticated;
