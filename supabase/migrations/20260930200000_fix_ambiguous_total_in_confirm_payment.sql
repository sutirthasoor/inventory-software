-- Fix ambiguous "total" column reference in confirm_payment
-- Qualified with table alias to avoid conflict with PL/pgSQL variable
create or replace function public.confirm_payment(p_payment_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $func$
declare
  v_user_id uuid := auth.uid();
  v_payment public.payments%rowtype;
  v_alloc record;
  v_target_total numeric(18,4);
  v_invoice_total numeric(18,4);
  v_invoice_paid numeric(18,4);
  v_balance numeric(18,4);
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;

  select * into v_payment from public.payments where id = p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;

  if not exists (
    select 1 from public.organization_users
    where organization_id = v_payment.organization_id and user_id = v_user_id
  ) then raise exception 'User is not a member of this organization'; end if;

  if v_payment.status <> 'Draft' then
    raise exception 'Only Draft payments can be confirmed';
  end if;

  if not exists (select 1 from public.payment_allocations where payment_id = v_payment.id) then
    raise exception 'Payment must have at least one allocation';
  end if;

  select coalesce(sum(allocated_amount), 0)
  into v_target_total
  from public.payment_allocations
  where payment_id = v_payment.id;

  if v_target_total <> v_payment.amount then
    raise exception 'Payment allocations (%) must equal payment amount (%)',
      v_target_total, v_payment.amount;
  end if;

  for v_alloc in
    select sale_id, purchase_id, expense_id, sum(allocated_amount) as allocated_amount
    from public.payment_allocations
    where payment_id = v_payment.id
    group by sale_id, purchase_id, expense_id
    order by sale_id nulls last, purchase_id nulls last, expense_id nulls last
  loop
    if v_payment.payment_type = 'In' and (v_alloc.purchase_id is not null or v_alloc.expense_id is not null) then
      raise exception 'Payment In can only be allocated to sales';
    end if;

    if v_payment.payment_type = 'Out' and v_alloc.sale_id is not null then
      raise exception 'Payment Out cannot be allocated to sales';
    end if;

    if v_alloc.sale_id is not null then
      select s.total into v_invoice_total
      from public.sales s
      where s.id = v_alloc.sale_id and s.organization_id = v_payment.organization_id
      for update;
      if not found then raise exception 'Sales invoice not found'; end if;

      if not exists (
        select 1 from public.sales s
        where s.id = v_alloc.sale_id and s.organization_id = v_payment.organization_id and s.status = 'Confirmed'
      ) then raise exception 'Sales invoice must be Confirmed before payment allocation'; end if;

      select coalesce(sum(pa.allocated_amount),0)
      into v_invoice_paid
      from public.payment_allocations pa
      join public.payments p on p.id = pa.payment_id
      where pa.sale_id = v_alloc.sale_id and p.status = 'Confirmed';

      v_balance := v_invoice_total - v_invoice_paid;
      if v_alloc.allocated_amount > v_balance then
        raise exception 'Sale allocation exceeds outstanding balance. Balance: %, requested: %',
          v_balance, v_alloc.allocated_amount;
      end if;
    elsif v_alloc.purchase_id is not null then
      select p.total into v_invoice_total
      from public.purchases p
      where p.id = v_alloc.purchase_id and p.organization_id = v_payment.organization_id
      for update;
      if not found then raise exception 'Purchase invoice not found'; end if;

      if not exists (
        select 1 from public.purchases p
        where p.id = v_alloc.purchase_id and p.organization_id = v_payment.organization_id and p.status = 'Confirmed'
      ) then raise exception 'Purchase invoice must be Confirmed before payment allocation'; end if;

      select coalesce(sum(pa.allocated_amount),0)
      into v_invoice_paid
      from public.payment_allocations pa
      join public.payments p on p.id = pa.payment_id
      where pa.purchase_id = v_alloc.purchase_id and p.status = 'Confirmed';

      v_balance := v_invoice_total - v_invoice_paid;
      if v_alloc.allocated_amount > v_balance then
        raise exception 'Purchase allocation exceeds outstanding balance. Balance: %, requested: %',
          v_balance, v_alloc.allocated_amount;
      end if;
    elsif v_alloc.expense_id is not null then
      select e.amount into v_invoice_total
      from public.expenses e
      where e.id = v_alloc.expense_id and e.organization_id = v_payment.organization_id
      for update;
      if not found then raise exception 'Expense not found'; end if;

      if not exists (
        select 1 from public.expenses e
        where e.id = v_alloc.expense_id and e.organization_id = v_payment.organization_id and e.status = 'Confirmed'
      ) then raise exception 'Expense must be Confirmed before payment allocation'; end if;

      select coalesce(sum(pa.allocated_amount),0)
      into v_invoice_paid
      from public.payment_allocations pa
      join public.payments p on p.id = pa.payment_id
      where pa.expense_id = v_alloc.expense_id and p.status = 'Confirmed';

      v_balance := v_invoice_total - v_invoice_paid;
      if v_alloc.allocated_amount > v_balance then
        raise exception 'Expense allocation exceeds outstanding balance. Balance: %, requested: %',
          v_balance, v_alloc.allocated_amount;
      end if;
    end if;
  end loop;

  insert into public.account_transactions (
    organization_id, transaction_date, transaction_type,
    reference_type, reference_id, contact_id, description, debit, credit, created_by
  )
  values (
    v_payment.organization_id, now(), 'Payment',
    'Payment', v_payment.id, v_payment.contact_id,
    case when v_payment.payment_type = 'In' then 'Payment received' else 'Payment made' end,
    case when v_payment.payment_type = 'Out' then v_payment.amount else 0 end,
    case when v_payment.payment_type = 'In' then v_payment.amount else 0 end,
    v_user_id
  );

  update public.payments
  set status = 'Confirmed', updated_at = now()
  where id = v_payment.id;
end;
$func$;

revoke all on function public.confirm_payment(uuid) from public;
grant execute on function public.confirm_payment(uuid) to authenticated;