-- Phase 7b: WAC inventory valuation layer only.
-- Extracted from the original phase7b production sync migration.
-- The RPC redefinitions in that file conflict with the canonical surface
-- already applied by 20260926230000_canonical_atomic_operations.sql
-- (different return types), so only the additive WAC + stock column parts
-- are applied here.

BEGIN;

ALTER TABLE public.stock ADD COLUMN IF NOT EXISTS average_cost numeric(18,8) NOT NULL DEFAULT 0;
ALTER TABLE public.stock ADD COLUMN IF NOT EXISTS inventory_value numeric(18,4) NOT NULL DEFAULT 0;

CREATE SCHEMA IF NOT EXISTS private;

CREATE OR REPLACE FUNCTION private.wac_in(o uuid, p uuid, q numeric, c numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare oq numeric;ov numeric;nq numeric;nv numeric;a numeric;
begin
 if q<=0 or c is null or c<0 then raise exception 'Invalid inbound cost'; end if;
 insert into public.stock(organization_id,product_id,quantity,average_cost,inventory_value) values(o,p,0,0,0) on conflict(organization_id,product_id) do nothing;
 select quantity,inventory_value into oq,ov from public.stock where organization_id=o and product_id=p for update;
 nq=oq+q;nv=ov+q*c;a=case when nq>0 then nv/nq else 0 end;
 update public.stock set quantity=round(nq,4),inventory_value=round(nv,4),average_cost=round(a,8),updated_at=now() where organization_id=o and product_id=p;
 return round(a,8);
end;
$function$;

CREATE OR REPLACE FUNCTION private.wac_out(o uuid, p uuid, q numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare oq numeric;ov numeric;a numeric;nv numeric;
begin
 if q<=0 then raise exception 'Invalid outbound quantity'; end if;
 select quantity,inventory_value,average_cost into oq,ov,a from public.stock where organization_id=o and product_id=p for update;
 if not found or oq<q then raise exception 'Insufficient stock for product %',p; end if;
 nv=ov-q*a;if nv < -0.01 then raise exception 'Inventory value would become negative for product %',p;end if;nv=greatest(nv,0);
 update public.stock set quantity=round(oq-q,4),inventory_value=round(nv,4),average_cost=case when oq-q>0 then round(a,8) else 0 end,updated_at=now() where organization_id=o and product_id=p;
 return round(a,8);
end;
$function$;

REVOKE ALL ON SCHEMA private FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION private.wac_in(uuid,uuid,numeric,numeric) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.wac_out(uuid,uuid,numeric) FROM PUBLIC, anon, authenticated;

COMMIT;