create index if not exists contacts_organization_created_by_idx
  on public.contacts (organization_id, created_by);

create index if not exists contacts_name_trgm_idx
  on public.contacts using gin (name extensions.gin_trgm_ops);

create index if not exists contacts_phone_trgm_idx
  on public.contacts using gin (phone extensions.gin_trgm_ops);

create index if not exists contacts_email_trgm_idx
  on public.contacts using gin ((email::text) extensions.gin_trgm_ops);