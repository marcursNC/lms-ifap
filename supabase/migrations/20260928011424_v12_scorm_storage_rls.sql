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