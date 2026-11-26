alter table public.sessions
  add column if not exists external_organizer_user_id text;

create index if not exists sessions_external_organizer_idx
  on public.sessions(external_organizer_user_id)
  where external_organizer_user_id is not null;