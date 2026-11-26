create or replace function app_private.verify_attestation(p_token uuid)
returns table (
  certificate_number text,
  learner_name text,
  course_title text,
  issued_at timestamptz,
  revoked_at timestamptz,
  issuer_name text
)
language sql
security definer
set search_path = public, pg_catalog
as $$
  select
    a.certificate_number,
    concat(l.first_name,' ',l.last_name),
    c.title,
    a.issued_at,
    a.revoked_at,
    a.issuer_name
  from attestations a
  join enrollments e on e.id=a.enrollment_id
  join learners l on l.id=e.learner_id
  join deployments d on d.id=e.deployment_id
  join courses c on c.id=d.course_id
  where a.verification_token=p_token;
$$;

revoke all on function app_private.verify_attestation(uuid) from public;
grant execute on function app_private.verify_attestation(uuid) to anon, authenticated;

drop function if exists public.verify_attestation(uuid);
create function public.verify_attestation(p_token uuid)
returns table (
  certificate_number text,
  learner_name text,
  course_title text,
  issued_at timestamptz,
  revoked_at timestamptz,
  issuer_name text
)
language sql
security invoker
set search_path = public, pg_catalog
as $$
  select * from app_private.verify_attestation(p_token);
$$;

revoke all on function public.verify_attestation(uuid) from public;
grant execute on function public.verify_attestation(uuid) to anon, authenticated;