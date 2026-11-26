
alter table public.courses add column if not exists objectives text;
alter table public.courses add column if not exists target_audience text;
alter table public.courses add column if not exists duration_minutes integer;
alter table public.courses add column if not exists modality text;
alter table public.courses add column if not exists prerequisites text;
alter table public.courses add column if not exists thumbnail_path text;
