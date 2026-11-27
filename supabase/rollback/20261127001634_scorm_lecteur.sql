-- Retour arrière de 20261127001634_scorm_lecteur.sql. Annuler d'abord le code de l'application.
-- Les paquets et tentatives enregistrés sont conservés ; les colonnes ajoutées disparaissent.
begin;
drop policy learning_activity_log_scorm_guard on public.learning_activity_log;
create or replace function public.remove_course_item(p_kind text, p_id uuid)
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

drop function public.scorm_register_package(uuid, uuid, text, text, numeric, integer, bigint);
drop function public.scorm_finalize_package(uuid);
drop function public.scorm_discard_package(uuid);
drop function public.scorm_open(uuid, uuid);
drop function public.scorm_resolve_ticket(text);
drop function public.scorm_save(uuid, uuid, uuid, jsonb);
drop table app_private.scorm_tickets;

drop policy scorm_storage_select on storage.objects;
drop policy scorm_storage_insert on storage.objects;
drop policy scorm_storage_delete on storage.objects;
update storage.buckets set file_size_limit = null where id = 'scorm-packages';
drop policy if exists scorm_storage_select on storage.objects;
create policy scorm_storage_select on storage.objects for select to authenticated
using (
  bucket_id='scorm-packages'
  and exists (
    select 1 from public.scorm_packages p
    where p.storage_path=name
  )
);

drop policy if exists scorm_storage_insert on storage.objects;
create policy scorm_storage_insert on storage.objects for insert to authenticated
with check (
  bucket_id='scorm-packages'
  and exists (
    select 1 from public.scorm_packages p
    join public.courses c on c.id=p.course_id
    where p.storage_path=name
      and (app_private.is_platform_admin() or app_private.is_org_member(c.owner_organization_id,array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role]))
  )
);

drop policy if exists scorm_storage_update on storage.objects;
create policy scorm_storage_update on storage.objects for update to authenticated
using (
  bucket_id='scorm-packages'
  and exists (select 1 from public.scorm_packages p join public.courses c on c.id=p.course_id where p.storage_path=name and (app_private.is_platform_admin() or app_private.is_org_member(c.owner_organization_id,array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role])))
)
with check (
  bucket_id='scorm-packages'
  and exists (select 1 from public.scorm_packages p join public.courses c on c.id=p.course_id where p.storage_path=name and (app_private.is_platform_admin() or app_private.is_org_member(c.owner_organization_id,array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role])))
);

drop policy if exists scorm_storage_delete on storage.objects;
create policy scorm_storage_delete on storage.objects for delete to authenticated
using (
  bucket_id='scorm-packages'
  and exists (select 1 from public.scorm_packages p join public.courses c on c.id=p.course_id where p.storage_path=name and (app_private.is_platform_admin() or app_private.is_org_member(c.owner_organization_id,array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role])))
);

drop policy scorm_packages_select on public.scorm_packages;
drop policy scorm_attempts_select on public.scorm_attempts;
drop policy if exists scorm_packages_select on public.scorm_packages;
create policy scorm_packages_select on public.scorm_packages for select to authenticated
using (exists(select 1 from public.courses c where c.id=course_id));

drop policy if exists scorm_packages_manage on public.scorm_packages;
create policy scorm_packages_manage on public.scorm_packages for all to authenticated
using (exists(select 1 from public.courses c where c.id=course_id and (app_private.is_platform_admin() or app_private.is_org_member(c.owner_organization_id,array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role]))))
with check (exists(select 1 from public.courses c where c.id=course_id and (app_private.is_platform_admin() or app_private.is_org_member(c.owner_organization_id,array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role]))));

drop policy if exists scorm_attempts_select on public.scorm_attempts;
create policy scorm_attempts_select on public.scorm_attempts for select to authenticated
using (exists(select 1 from public.enrollments e join public.learners l on l.id=e.learner_id join public.scorm_packages p on p.id=scorm_package_id where e.id=enrollment_id and (l.user_id=(select auth.uid()) or app_private.is_platform_admin() or app_private.is_org_member(l.organization_id))));

drop policy if exists scorm_attempts_insert on public.scorm_attempts;
create policy scorm_attempts_insert on public.scorm_attempts for insert to authenticated
with check (exists(select 1 from public.enrollments e join public.learners l on l.id=e.learner_id join public.deployments d on d.id=e.deployment_id join public.scorm_packages p on p.id=scorm_package_id where e.id=enrollment_id and p.course_id=(select course_id from public.deployments where id=e.deployment_id) and (l.user_id=(select auth.uid()) or app_private.is_platform_admin() or app_private.is_org_member(l.organization_id,array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role]))));

drop policy if exists scorm_attempts_update on public.scorm_attempts;
create policy scorm_attempts_update on public.scorm_attempts for update to authenticated
using (exists(select 1 from public.enrollments e join public.learners l on l.id=e.learner_id where e.id=enrollment_id and (l.user_id=(select auth.uid()) or app_private.is_platform_admin() or app_private.is_org_member(l.organization_id,array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role]))))
with check (exists(select 1 from public.enrollments e join public.learners l on l.id=e.learner_id where e.id=enrollment_id and (l.user_id=(select auth.uid()) or app_private.is_platform_admin() or app_private.is_org_member(l.organization_id,array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role]))));

grant insert, update, delete, truncate on public.scorm_packages, public.scorm_attempts to anon, authenticated;

drop function app_private.can_import_scorm(uuid);
drop function app_private.scorm_package_of(text);
drop function app_private.token_hash(text);
drop function app_private.scorm_learner_access(uuid, uuid);
drop function app_private.is_scorm_resource(uuid);
drop function app_private.has_scorm_attempt(uuid[]);

drop index public.scorm_packages_resource_unique;
alter table public.scorm_packages
  drop constraint scorm_packages_status_check,
  drop constraint scorm_packages_path_check,
  drop constraint scorm_packages_size_check,
  drop constraint scorm_packages_mastery_check,
  drop column status, drop column module_id, drop column file_count,
  drop column total_bytes, drop column mastery_score;
commit;
