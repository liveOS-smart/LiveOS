-- LiveOS cloud sync: account-scoped application snapshot plus normalized data mirrors.
-- This SQL was applied to Supabase project hwopliqwicmzpeuvzvlk.
-- Both RPC functions use SECURITY INVOKER so table grants and RLS remain in effect.

create table if not exists public.liveos_app_states (
  user_id uuid primary key references auth.users(id) on delete cascade,
  state jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.liveos_app_states enable row level security;

drop policy if exists liveos_app_states_select_own on public.liveos_app_states;
create policy liveos_app_states_select_own
  on public.liveos_app_states for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists liveos_app_states_insert_own on public.liveos_app_states;
create policy liveos_app_states_insert_own
  on public.liveos_app_states for insert to authenticated
  with check ((select auth.uid()) = user_id);

drop policy if exists liveos_app_states_update_own on public.liveos_app_states;
create policy liveos_app_states_update_own
  on public.liveos_app_states for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists liveos_app_states_delete_own on public.liveos_app_states;
create policy liveos_app_states_delete_own
  on public.liveos_app_states for delete to authenticated
  using ((select auth.uid()) = user_id);

revoke all on table public.liveos_app_states from public, anon;
grant select, insert, update, delete on table public.liveos_app_states to authenticated;

create or replace function public.liveos_load_app_state()
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_state jsonb;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select s.state into v_state
    from public.liveos_app_states as s
   where s.user_id = v_user_id;

  if not found then
    return jsonb_build_object(
      'initialized', false,
      'state', jsonb_build_object(
        'monthlyIncome', 0,
        'expenses', '[]'::jsonb,
        'events', '[]'::jsonb,
        'tasks', '[]'::jsonb,
        'lists', '[]'::jsonb,
        'notes', '[]'::jsonb
      )
    );
  end if;

  return jsonb_build_object('initialized', true, 'state', v_state);
end;
$function$;

create or replace function public.liveos_sync_app_state(p_state jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_now timestamptz := now();
  v_income numeric(14,2);
  v_row jsonb;
  v_item jsonb;
  v_list_id uuid;
  v_default_task_list_id uuid;
  v_category_id uuid;
  v_kind text;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if p_state is null or jsonb_typeof(p_state) <> 'object' then
    raise exception 'Invalid LiveOS state';
  end if;
  if pg_catalog.pg_column_size(p_state) > 1000000 then
    raise exception 'LiveOS state is too large';
  end if;

  if jsonb_typeof(coalesce(p_state -> 'expenses', '[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_state -> 'events', '[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_state -> 'tasks', '[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_state -> 'lists', '[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_state -> 'notes', '[]'::jsonb)) <> 'array' then
    raise exception 'Invalid LiveOS collection';
  end if;

  insert into public.liveos_app_states(user_id, state, updated_at)
  values (v_user_id, p_state, v_now)
  on conflict (user_id) do update
    set state = excluded.state,
        updated_at = excluded.updated_at;

  delete from public.income_sources
   where user_id = v_user_id and note = 'liveos:monthly-income';

  v_income := greatest(coalesce(nullif(p_state ->> 'monthlyIncome', '')::numeric, 0), 0);
  if v_income > 0 then
    insert into public.income_sources(
      user_id, name, expected_amount, currency_code, frequency, is_active, note
    )
    values (
      v_user_id, 'Monatliches Einkommen', v_income, 'EUR', 'monthly', true,
      'liveos:monthly-income'
    );
  end if;

  delete from public.financial_transactions
   where user_id = v_user_id and source = 'manual';

  for v_row in
    select value from jsonb_array_elements(coalesce(p_state -> 'expenses', '[]'::jsonb))
  loop
    if nullif(pg_catalog.btrim(coalesce(v_row ->> 'title', '')), '') is null
       or coalesce(nullif(v_row ->> 'amount', '')::numeric, 0) <= 0 then
      continue;
    end if;

    v_category_id := null;
    select c.id into v_category_id
      from public.financial_categories as c
     where lower(c.name) = lower(
       case lower(coalesce(v_row ->> 'category', ''))
         when 'essen' then 'lebensmittel'
         else coalesce(v_row ->> 'category', '')
       end
     )
       and (c.is_system = true or c.user_id = v_user_id)
       and c.kind = 'expense'
     order by c.is_system desc
     limit 1;

    insert into public.financial_transactions(
      user_id, category_id, kind, title, amount, currency_code, transaction_at, note, source
    )
    values (
      v_user_id, v_category_id, 'expense',
      pg_catalog.left(pg_catalog.btrim(v_row ->> 'title'), 160),
      (v_row ->> 'amount')::numeric, 'EUR',
      coalesce(nullif(v_row ->> 'date', '')::date, current_date)::timestamp
        at time zone 'Europe/Berlin',
      null, 'manual'
    );
  end loop;

  delete from public.calendar_events where user_id = v_user_id;

  for v_row in
    select value from jsonb_array_elements(coalesce(p_state -> 'events', '[]'::jsonb))
  loop
    if nullif(pg_catalog.btrim(coalesce(v_row ->> 'title', '')), '') is null
       or nullif(v_row ->> 'date', '') is null then
      continue;
    end if;

    v_kind := case coalesce(v_row ->> 'type', 'Termin')
      when 'Anruf' then 'call'
      when 'Geburtstag' then 'birthday'
      when 'Erinnerung' then 'other'
      else 'event'
    end;

    insert into public.calendar_events(
      user_id, title, description, starts_at, is_all_day, event_type
    )
    values (
      v_user_id,
      pg_catalog.left(pg_catalog.btrim(v_row ->> 'title'), 160),
      nullif(v_row ->> 'note', ''),
      (
        coalesce(nullif(v_row ->> 'date', '')::date, current_date)::timestamp
        + case
            when nullif(v_row ->> 'time', '') is not null
              then nullif(v_row ->> 'time', '')::time
            else time '00:00'
          end
      ) at time zone 'Europe/Berlin',
      nullif(v_row ->> 'time', '') is null,
      v_kind
    );
  end loop;

  delete from public.list_items
   where user_id = v_user_id
     and list_id in (
       select tl.id
         from public.task_lists as tl
        where tl.user_id = v_user_id
          and tl.description in ('liveos:default-tasks', 'liveos:custom-list')
     );
  delete from public.task_lists
   where user_id = v_user_id
     and description in ('liveos:default-tasks', 'liveos:custom-list');

  if jsonb_array_length(coalesce(p_state -> 'tasks', '[]'::jsonb)) > 0 then
    insert into public.task_lists(user_id, title, description, list_type, sort_order)
    values (v_user_id, 'Meine Aufgaben', 'liveos:default-tasks', 'todo', 0)
    returning id into v_default_task_list_id;

    for v_row in
      select value from jsonb_array_elements(coalesce(p_state -> 'tasks', '[]'::jsonb))
    loop
      if nullif(pg_catalog.btrim(coalesce(v_row ->> 'title', '')), '') is null then
        continue;
      end if;

      insert into public.list_items(
        user_id, list_id, title, is_completed, priority, due_at, completed_at, sort_order
      )
      values (
        v_user_id, v_default_task_list_id,
        pg_catalog.left(pg_catalog.btrim(v_row ->> 'title'), 240),
        coalesce(nullif(v_row ->> 'done', '')::boolean, false),
        case coalesce(v_row ->> 'priority', 'Normal')
          when 'Hoch' then 'high'
          when 'Niedrig' then 'low'
          else 'normal'
        end,
        case when nullif(v_row ->> 'due', '') is null then null
          else (v_row ->> 'due')::date::timestamp at time zone 'Europe/Berlin'
        end,
        case when coalesce(nullif(v_row ->> 'done', '')::boolean, false) then v_now else null end,
        0
      );
    end loop;
  end if;

  for v_row in
    select value from jsonb_array_elements(coalesce(p_state -> 'lists', '[]'::jsonb))
  loop
    if nullif(pg_catalog.btrim(coalesce(v_row ->> 'title', '')), '') is null then
      continue;
    end if;

    insert into public.task_lists(user_id, title, description, list_type, sort_order)
    values (
      v_user_id, pg_catalog.left(pg_catalog.btrim(v_row ->> 'title'), 120),
      'liveos:custom-list', 'other', 0
    )
    returning id into v_list_id;

    for v_item in
      select value from jsonb_array_elements(coalesce(v_row -> 'items', '[]'::jsonb))
    loop
      if nullif(pg_catalog.btrim(coalesce(v_item ->> 'title', '')), '') is null then
        continue;
      end if;
      insert into public.list_items(
        user_id, list_id, title, is_completed, priority, sort_order, completed_at
      )
      values (
        v_user_id, v_list_id,
        pg_catalog.left(pg_catalog.btrim(v_item ->> 'title'), 240),
        coalesce(nullif(v_item ->> 'done', '')::boolean, false),
        'normal', 0,
        case when coalesce(nullif(v_item ->> 'done', '')::boolean, false) then v_now else null end
      );
    end loop;
  end loop;

  delete from public.notes where user_id = v_user_id;

  for v_row in
    select value from jsonb_array_elements(coalesce(p_state -> 'notes', '[]'::jsonb))
  loop
    insert into public.notes(user_id, title, body, is_pinned)
    values (
      v_user_id, pg_catalog.left(coalesce(v_row ->> 'title', ''), 200),
      coalesce(v_row ->> 'body', ''), false
    );
  end loop;

  return jsonb_build_object('ok', true, 'updated_at', v_now);
end;
$function$;

revoke all on function public.liveos_load_app_state() from public, anon;
revoke all on function public.liveos_sync_app_state(jsonb) from public, anon;
grant execute on function public.liveos_load_app_state() to authenticated;
grant execute on function public.liveos_sync_app_state(jsonb) to authenticated;

do $publication$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename = 'liveos_app_states'
     ) then
    alter publication supabase_realtime add table public.liveos_app_states;
  end if;
end;
$publication$;
