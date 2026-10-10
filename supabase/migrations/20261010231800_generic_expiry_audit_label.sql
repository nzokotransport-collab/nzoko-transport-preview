-- Keep expiry audit wording accurate for both legacy 72-hour reservations and new 24-hour reservations.
-- This changes no reservation rows or expiration timestamps.
CREATE OR REPLACE FUNCTION public.cancel_expired_reservations()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_count integer;
BEGIN
  WITH candidates AS (
    SELECT r.id FROM public.reservations r
    WHERE r.status = 'pending' AND r.expires_at <= clock_timestamp()
    ORDER BY r.expires_at, r.id
    FOR UPDATE SKIP LOCKED
  ), expired AS (
    UPDATE public.reservations r
    SET status = 'cancelled', cancellation_reason = 'expired_72h',
        expired_at = clock_timestamp(), seat_number = NULL,
        qr_code_data = r.reference_code, updated_at = clock_timestamp()
    FROM candidates c
    WHERE r.id = c.id
    RETURNING r.id, r.reference_code, r.booking_channel, r.amount, r.created_at, r.expired_at
  )
  INSERT INTO public.audit_logs (
    user_id, user_name, role, agency_id, agency_name, action, module,
    entity_type, entity_id, old_values, new_values
  )
  SELECT NULL, 'Système', 'system', NULL, 'Automatique', 'EXPIRATION_RESERVATION_72H',
    'Réservations', 'Reservation', e.id::text,
    jsonb_build_object('status', 'pending'),
    jsonb_build_object('event_label', 'Réservation expirée automatiquement à son échéance de paiement',
      'reference_code', e.reference_code, 'booking_channel', e.booking_channel,
      'amount', e.amount, 'status', 'cancelled', 'expired_at', e.expired_at)
  FROM expired e;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  WITH released AS (
    DELETE FROM public.reservation_claims c
    USING public.reservations r
    WHERE r.id = c.reservation_id
      AND r.status = 'cancelled'
      AND r.cancellation_reason = 'expired_72h'
      AND r.expired_at >= clock_timestamp() - interval '2 minutes'
    RETURNING c.reservation_id, c.claimed_by_name, c.agency_id, c.agency_name, c.expires_at
  )
  INSERT INTO public.audit_logs (
    user_id, user_name, role, agency_id, agency_name, action, module,
    entity_type, entity_id, old_values, new_values
  )
  SELECT NULL, 'Système', 'system', c.agency_id, c.agency_name,
    'EXPIRATION_PRISE_EN_CHARGE_WEB', 'Réservations', 'Reservation', c.reservation_id::text,
    jsonb_build_object('agent_name', c.claimed_by_name, 'agency_name', c.agency_name,
      'expires_at', c.expires_at),
    jsonb_build_object('event_label', 'Prise en charge libérée avec l’expiration du billet',
      'released_at', clock_timestamp())
  FROM released c;
  RETURN v_count;
END;
$function$;
