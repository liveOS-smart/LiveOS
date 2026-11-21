-- LiveOS reminders sync migration (applied to the LiveOS Supabase project).
alter table public.reminders
  add column if not exists client_id uuid,
  add column if not exists source text not null default 'manual';

alter table public.reminders
  drop constraint if exists reminders_source_check;
alter table public.reminders
  add constraint reminders_source_check
  check (source in ('manual','liveos-app'));

create unique index if not exists reminders_user_client_id_uidx
  on public.reminders(user_id, client_id)
  where client_id is not null;

create index if not exists reminders_due_user_idx
  on public.reminders(user_id, scheduled_at)
  where is_enabled = true;

create or replace function public.liveos_sync_reminders(p_reminders jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_row jsonb;
  v_repeat text;
  v_client_id uuid;
  v_count integer := 0;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if p_reminders is null or jsonb_typeof(p_reminders) <> 'array' then
    raise exception 'Invalid reminders payload';
  end if;
  if jsonb_array_length(p_reminders) > 200 then raise exception 'Too many reminders'; end if;

  for v_row in select value from jsonb_array_elements(p_reminders)
  loop
    if nullif(pg_catalog.btrim(coalesce(v_row ->> 'title','')), '') is null
       or nullif(v_row ->> 'id','') is null
       or nullif(v_row ->> 'scheduledAt','') is null then
      raise exception 'Reminder requires id, title and scheduledAt';
    end if;
    perform (v_row ->> 'id')::uuid;
    perform (v_row ->> 'scheduledAt')::timestamptz;
    if coalesce(v_row ->> 'repeat','none') not in ('none','daily','weekly','monthly') then
      raise exception 'Invalid reminder recurrence';
    end if;
    if pg_catalog.length(v_row ->> 'title') > 160 then raise exception 'Reminder title is too long'; end if;
  end loop;

  delete from public.reminders as r
   where r.user_id = v_user_id
     and r.source = 'liveos-app'
     and not exists (
       select 1 from jsonb_array_elements(p_reminders) as incoming(value)
       where incoming.value ->> 'id' = r.client_id::text
     );

  for v_row in select value from jsonb_array_elements(p_reminders)
  loop
    v_client_id := (v_row ->> 'id')::uuid;
    v_repeat := case coalesce(v_row ->> 'repeat','none')
      when 'daily' then 'FREQ=DAILY'
      when 'weekly' then 'FREQ=WEEKLY'
      when 'monthly' then 'FREQ=MONTHLY'
      else null
    end;

    insert into public.reminders(
      user_id, client_id, source, title, message, scheduled_at,
      recurrence_rule, channel, is_enabled, sent_at
    )
    values (
      v_user_id, v_client_id, 'liveos-app',
      pg_catalog.left(pg_catalog.btrim(v_row ->> 'title'),160),
      nullif(v_row ->> 'message',''),
      (v_row ->> 'scheduledAt')::timestamptz,
      v_repeat, 'in_app',
      coalesce(nullif(v_row ->> 'enabled','')::boolean,true),
      nullif(v_row ->> 'sentAt','')::timestamptz
    )
    on conflict (user_id, client_id) where client_id is not null
    do update set
      source=excluded.source,title=excluded.title,message=excluded.message,
      scheduled_at=excluded.scheduled_at,recurrence_rule=excluded.recurrence_rule,
      channel=excluded.channel,is_enabled=excluded.is_enabled,sent_at=excluded.sent_at,
      updated_at=now();

    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('ok',true,'count',v_count);
end;
$function$;

revoke all on function public.liveos_sync_reminders(jsonb) from public, anon;
grant execute on function public.liveos_sync_reminders(jsonb) to authenticated;
