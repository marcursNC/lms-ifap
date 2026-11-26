drop policy if exists attestations_select on public.attestations;
create policy attestations_select on public.attestations
for select to authenticated
using (
  exists (
    select 1
    from public.enrollments e
    join public.learners l on l.id=e.learner_id
    where e.id=attestations.enrollment_id
      and (
        l.user_id=auth.uid()
        or app_private.is_platform_admin()
        or app_private.is_org_member(l.organization_id, array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role])
      )
  )
);

drop policy if exists enrollments_select on public.enrollments;
create policy enrollments_select on public.enrollments
for select to authenticated
using (
  app_private.is_platform_admin()
  or exists (
    select 1 from public.learners l
    where l.id=enrollments.learner_id
      and (
        l.user_id=auth.uid()
        or app_private.is_org_member(l.organization_id, array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role])
      )
  )
);

drop policy if exists learners_select on public.learners;
create policy learners_select on public.learners
for select to authenticated
using (
  app_private.is_platform_admin()
  or user_id=auth.uid()
  or app_private.is_org_member(organization_id, array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role])
);

drop policy if exists certificates_select on storage.objects;
create policy certificates_select on storage.objects
for select to authenticated
using (
  bucket_id='certificates'
  and exists (
    select 1
    from public.attestations a
    join public.enrollments e on e.id=a.enrollment_id
    join public.learners l on l.id=e.learner_id
    where a.pdf_path=objects.name
      and (
        l.user_id=auth.uid()
        or app_private.is_platform_admin()
        or app_private.is_org_member(l.organization_id, array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role])
      )
  )
);