insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('certificates','certificates',false,10485760,array['application/pdf'])
on conflict (id) do update set public=false,file_size_limit=10485760,allowed_mime_types=array['application/pdf'];

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
    where a.pdf_path=name
      and (
        app_private.is_platform_admin()
        or app_private.is_org_member(l.organization_id)
        or l.user_id=auth.uid()
      )
  )
);

drop policy if exists certificates_insert on storage.objects;
create policy certificates_insert on storage.objects
for insert to authenticated
with check (
  bucket_id='certificates'
  and exists (
    select 1
    from public.attestations a
    join public.enrollments e on e.id=a.enrollment_id
    join public.learners l on l.id=e.learner_id
    where a.pdf_path=name
      and app_private.is_org_member(l.organization_id, ARRAY['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role])
  )
);

drop policy if exists certificates_update on storage.objects;
create policy certificates_update on storage.objects
for update to authenticated
using (
  bucket_id='certificates'
  and exists (
    select 1
    from public.attestations a
    join public.enrollments e on e.id=a.enrollment_id
    join public.learners l on l.id=e.learner_id
    where a.pdf_path=name
      and app_private.is_org_member(l.organization_id, ARRAY['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role])
  )
)
with check (bucket_id='certificates');

create index if not exists attestations_enrollment_unique_idx on public.attestations(enrollment_id);

create or replace function app_private.set_certificate_pdf_path()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
  if new.pdf_path is null then
    new.pdf_path := 'attestations/' || new.id::text || '.pdf';
  end if;
  return new;
end;
$$;

revoke all on function app_private.set_certificate_pdf_path() from public;

drop trigger if exists attestation_pdf_path on public.attestations;
create trigger attestation_pdf_path
before insert on public.attestations
for each row execute function app_private.set_certificate_pdf_path();