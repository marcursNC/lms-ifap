alter table public.attestations
  add column if not exists certificate_number text,
  add column if not exists issued_at timestamptz not null default now(),
  add column if not exists revoked_at timestamptz,
  add column if not exists pdf_path text,
  add column if not exists verification_url text,
  add column if not exists issuer_name text;

create unique index if not exists attestations_certificate_number_uidx
  on public.attestations(certificate_number)
  where certificate_number is not null;

create or replace function app_private.generate_certificate_number()
returns trigger language plpgsql set search_path=public,pg_catalog as $$
begin
  if new.certificate_number is null then
    new.certificate_number := 'IFAP-' || to_char(coalesce(new.issued_at,now()),'YYYY') || '-' || upper(substr(replace(new.id::text,'-',''),1,10));
  end if;
  return new;
end; $$;

drop trigger if exists attestations_certificate_number on public.attestations;
create trigger attestations_certificate_number before insert on public.attestations for each row execute function app_private.generate_certificate_number();