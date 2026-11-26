create or replace function app_private.enforce_attestation_eligibility()
returns trigger language plpgsql set search_path=public,pg_catalog as $$
declare v_progress numeric; v_completed_at timestamptz;
begin
  select progress,completed_at into v_progress,v_completed_at from public.enrollments where id=new.enrollment_id;
  if v_progress is null or v_progress < 100 or v_completed_at is null then
    raise exception 'Attestation requires a completed enrollment with 100 percent progress';
  end if;
  return new;
end; $$;

drop trigger if exists attestations_eligibility on public.attestations;
create trigger attestations_eligibility before insert on public.attestations for each row execute function app_private.enforce_attestation_eligibility();

create or replace function app_private.create_attestation_event()
returns trigger language plpgsql set search_path=public,pg_catalog as $$
begin
  insert into public.event_outbox(event_type,aggregate_type,aggregate_id,payload)
  values ('certificate.issued','attestation',new.id,
    jsonb_build_object('attestation_id',new.id,'enrollment_id',new.enrollment_id,'certificate_number',new.certificate_number,'verification_token',new.verification_token));
  return new;
end; $$;

drop trigger if exists attestations_event_trigger on public.attestations;
create trigger attestations_event_trigger after insert on public.attestations for each row execute function app_private.create_attestation_event();

create index if not exists attestations_enrollment_idx on public.attestations(enrollment_id);
create index if not exists attestations_issued_at_idx on public.attestations(issued_at);