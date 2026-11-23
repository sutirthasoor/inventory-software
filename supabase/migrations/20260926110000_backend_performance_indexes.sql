create index if not exists products_uom_organization_idx
  on public.products (uom_id, organization_id);

create index if not exists units_of_measure_active_organization_name_idx
  on public.units_of_measure (organization_id, name)
  where status = 'Active';

create index if not exists products_product_name_trgm_idx
  on public.products using gin (product_name extensions.gin_trgm_ops);