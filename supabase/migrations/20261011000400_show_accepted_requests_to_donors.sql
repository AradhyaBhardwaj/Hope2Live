create or replace function public.get_donor_accepted_blood_requests()
returns setof public.blood_requests
language sql
stable
security definer
set search_path = ''
set row_security = off
as $$
  select request.*
  from public.blood_requests as request
  where request.status <> 'Cancelled'
    and exists (
      select 1
      from public.blood_request_responses as donor_response
      where donor_response.request_id = request.id
        and donor_response.donor_id = (select auth.uid())
        and donor_response.status in ('Accepted', 'Completed')
    )
  order by request.created_at desc;
$$;

revoke all on function public.get_donor_accepted_blood_requests() from public;
grant execute on function public.get_donor_accepted_blood_requests() to authenticated;
