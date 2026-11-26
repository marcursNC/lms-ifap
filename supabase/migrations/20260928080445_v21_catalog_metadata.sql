alter table public.courses
  add column if not exists category text,
  add column if not exists level text,
  add column if not exists tags text[] not null default '{}',
  add column if not exists featured boolean not null default false;

create index if not exists courses_catalog_filter_idx
  on public.courses(status,visibility,category,featured,updated_at desc);

create index if not exists courses_tags_gin_idx
  on public.courses using gin(tags);