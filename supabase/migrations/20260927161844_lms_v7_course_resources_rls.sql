
create policy course_resources_select on public.course_resources
for select to authenticated
using (exists (select 1 from public.courses c where c.id = course_id));

create policy course_resources_manage on public.course_resources
for all to authenticated
using (
 exists (
   select 1 from public.courses c
   where c.id = course_id
   and (
     app_private.is_platform_admin()
     or app_private.is_org_member(c.owner_organization_id, array['org_admin','trainer','platform_admin']::member_role[])
   )
 )
)
with check (
 exists (
   select 1 from public.courses c
   where c.id = course_id
   and (
     app_private.is_platform_admin()
     or app_private.is_org_member(c.owner_organization_id, array['org_admin','trainer','platform_admin']::member_role[])
   )
 )
);
