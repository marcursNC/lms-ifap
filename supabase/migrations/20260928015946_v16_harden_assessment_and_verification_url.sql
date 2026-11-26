drop policy if exists attempts_manage on public.evaluation_attempts;
create policy attempts_manage on public.evaluation_attempts
for all to authenticated
using (
  exists (
    select 1 from learners l
    where l.id=evaluation_attempts.learner_id
      and app_private.is_org_member(l.organization_id, ARRAY['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role])
  )
)
with check (
  exists (
    select 1 from learners l
    where l.id=evaluation_attempts.learner_id
      and app_private.is_org_member(l.organization_id, ARRAY['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role])
  )
);

create or replace function app_private.issue_attestation_on_completion()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_org_name text;
  v_token uuid;
begin
  if new.status='completed' and new.completed_at is not null
     and not exists (select 1 from public.attestations a where a.enrollment_id=new.id) then
    select o.name into v_org_name
    from public.learners l
    join public.organizations o on o.id=l.organization_id
    where l.id=new.learner_id;

    v_token := gen_random_uuid();
    insert into public.attestations (
      enrollment_id, verification_token, issuer_name, verification_url
    )
    values (
      new.id,
      v_token,
      coalesce(v_org_name,'IFAP'),
      '/verify/' || v_token::text
    );
  end if;
  return new;
end;
$$;

revoke all on function app_private.issue_attestation_on_completion() from public;