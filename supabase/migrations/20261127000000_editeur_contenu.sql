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
