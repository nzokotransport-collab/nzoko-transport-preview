-- NZOKO: 24-hour pending ticket validity and admin-controlled booking classes.
-- Existing reservations are deliberately left untouched; this migration changes
-- defaults and creation-time rules only. A retroactive update requires a separate decision.
-- Keep the legacy expired_72h reason/action identifiers for compatibility with
-- agent validation and existing booking reports; their user-facing event label now says 24 hours.

ALTER TABLE public.site_settings
  ADD COLUMN IF NOT EXISTS booking_class_vip_enabled boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS booking_class_standard_enabled boolean NOT NULL DEFAULT true;

ALTER TABLE public.reservations
  ALTER COLUMN expires_at SET DEFAULT (now() + interval '24 hours');

CREATE OR REPLACE FUNCTION public.create_public_reservation(
  p_reference_code text,
  p_trip_id uuid,
  p_passenger_name text,
  p_passenger_first_name text,
  p_passenger_phone text,
  p_birth_place text,
  p_has_id_card boolean,
  p_id_card_type text,
  p_id_card_number text,
  p_class_type text,
  p_seat_number text,
  p_amount numeric,
  p_qr_code_data text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_trip public.trips%ROWTYPE;
  v_bus public.buses%ROWTYPE;
  v_class text := lower(btrim(COALESCE(p_class_type, '')));
  v_min_seat integer;
  v_max_seat integer;
  v_has_open_seat boolean;
  v_ref text;
  v_id uuid;
  v_amount numeric;
  v_expires timestamptz := clock_timestamp() + interval '24 hours';
  v_passenger text;
  v_class_enabled boolean;
BEGIN
  IF p_trip_id IS NULL THEN RAISE EXCEPTION 'TRIP_NOT_FOUND'; END IF;
  IF v_class NOT IN ('vip', 'standard') THEN RAISE EXCEPTION 'INVALID_CLASS'; END IF;
  SELECT CASE WHEN v_class = 'vip'
    THEN s.booking_class_vip_enabled ELSE s.booking_class_standard_enabled END
    INTO v_class_enabled
    FROM public.site_settings s WHERE s.id = 1 FOR SHARE;
  IF NOT COALESCE(v_class_enabled, true) THEN RAISE EXCEPTION 'CLASS_DISABLED'; END IF;
  IF NULLIF(btrim(p_passenger_name), '') IS NULL
     OR NULLIF(btrim(p_passenger_first_name), '') IS NULL
     OR NULLIF(btrim(p_passenger_phone), '') IS NULL
     OR length(regexp_replace(COALESCE(p_passenger_phone, ''), '[^0-9]', '', 'g')) < 8
     OR NULLIF(btrim(p_birth_place), '') IS NULL THEN
    RAISE EXCEPTION 'PASSENGER_DETAILS_REQUIRED';
  END IF;
  IF COALESCE(p_has_id_card, false)
     AND (NULLIF(btrim(p_id_card_type), '') IS NULL OR NULLIF(btrim(p_id_card_number), '') IS NULL) THEN
    RAISE EXCEPTION 'ID_CARD_DETAILS_REQUIRED';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_trip_id::text, 0));
  SELECT * INTO v_trip FROM public.trips WHERE id = p_trip_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'TRIP_NOT_FOUND'; END IF;
  IF v_trip.status NOT IN ('scheduled', 'boarding') THEN RAISE EXCEPTION 'TRIP_NOT_BOOKABLE'; END IF;
  IF v_trip.departure_date + v_trip.departure_time <= (clock_timestamp() AT TIME ZONE 'Africa/Brazzaville') THEN
    RAISE EXCEPTION 'TRIP_ALREADY_DEPARTED';
  END IF;
  SELECT * INTO v_bus FROM public.buses WHERE id = v_trip.bus_id;
  IF NOT FOUND OR v_bus.total_seats IS NULL OR v_bus.total_seats <= 0 THEN
    RAISE EXCEPTION 'BUS_NOT_ASSIGNED_OR_CAPACITY_INVALID';
  END IF;

  v_min_seat := CASE WHEN v_class = 'vip' THEN 1 ELSE 17 END;
  v_max_seat := CASE WHEN v_class = 'vip' THEN LEAST(16, v_bus.total_seats) ELSE v_bus.total_seats END;
  SELECT EXISTS (
    SELECT 1 FROM generate_series(v_min_seat, v_max_seat) AS seat_no
    WHERE NOT EXISTS (
      SELECT 1 FROM public.reservations r
      WHERE r.trip_id = v_trip.id
        AND r.seat_number = CASE WHEN seat_no < 10 THEN '0' || seat_no::text ELSE seat_no::text END
        AND r.status IN ('confirmed', 'boarded')
    )
  ) INTO v_has_open_seat;
  IF NOT v_has_open_seat THEN RAISE EXCEPTION 'NO_SEAT_AVAILABLE'; END IF;

  v_ref := format('NZK-%s-%s', to_char(clock_timestamp(), 'YYYYMMDD'), lpad(nextval('public.ticket_number_seq')::text, 6, '0'));
  v_amount := CASE WHEN v_class = 'vip' THEN v_trip.price_vip ELSE v_trip.price_standard END;
  v_passenger := concat_ws(' ', btrim(p_passenger_first_name), btrim(p_passenger_name));

  INSERT INTO public.reservations (
    reference_code, trip_id, passenger_name, passenger_first_name, passenger_phone,
    birth_place, has_id_card, id_card_type, id_card_number, class_type,
    seat_number, amount, payment_method, qr_code_data, status, expires_at, booking_channel
  ) VALUES (
    v_ref, v_trip.id, btrim(p_passenger_name), btrim(p_passenger_first_name), btrim(p_passenger_phone),
    btrim(p_birth_place), COALESCE(p_has_id_card, false),
    CASE WHEN p_has_id_card THEN NULLIF(btrim(p_id_card_type), '') ELSE NULL END,
    CASE WHEN p_has_id_card THEN NULLIF(btrim(p_id_card_number), '') ELSE NULL END,
    v_class, NULL, v_amount, 'cash', v_ref, 'pending', v_expires, 'online'
  ) RETURNING id INTO v_id;

  INSERT INTO public.audit_logs (
    user_id, user_name, role, agency_id, agency_name, action, module,
    entity_type, entity_id, old_values, new_values
  ) VALUES (
    auth.uid(), v_passenger, 'user', NULL, 'Réservation en ligne',
    'CREATION_RESERVATION_WEB', 'Réservations', 'Reservation', v_id::text, NULL,
    jsonb_build_object(
      'event_label', 'Nouvelle réservation web en attente de paiement',
      'booking_channel', 'online', 'reference_code', v_ref,
      'passenger_name', v_passenger,
      'trip_number', v_trip.trip_number,
      'route', concat_ws(' → ', v_trip.departure_city, v_trip.arrival_city),
      'trip_date', v_trip.departure_date, 'trip_time', v_trip.departure_time,
      'class_type', v_class, 'seat_number', NULL, 'amount', v_amount,
      'status', 'pending', 'reserved_at', clock_timestamp(), 'expires_at', v_expires
    )
  );

  RETURN jsonb_build_object(
    'id', v_id, 'reference_code', v_ref, 'trip_id', v_trip.id,
    'class_type', v_class, 'seat_number', NULL, 'status', 'pending',
    'amount', v_amount, 'created_at', clock_timestamp(), 'expires_at', v_expires,
    'qr_code_data', v_ref, 'cancellation_reason', NULL,
    'trip', jsonb_build_object(
      'id', v_trip.id, 'trip_number', v_trip.trip_number,
      'departure_city', v_trip.departure_city, 'arrival_city', v_trip.arrival_city,
      'departure_time', v_trip.departure_time, 'arrival_time', v_trip.arrival_time,
      'departure_date', v_trip.departure_date, 'bus_id', v_trip.bus_id,
      'price_standard', v_trip.price_standard, 'price_vip', v_trip.price_vip,
      'available_seats', v_trip.available_seats, 'status', v_trip.status,
      'bus', jsonb_build_object('id', v_bus.id, 'name', v_bus.name,
        'plate_number', v_bus.plate_number, 'total_seats', v_bus.total_seats,
        'class_type', v_bus.class_type, 'status', v_bus.status)
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_agent_reservation(
  p_trip_id uuid,
  p_passenger_name text,
  p_passenger_first_name text,
  p_passenger_phone text,
  p_birth_place text,
  p_has_id_card boolean,
  p_id_card_type text,
  p_id_card_number text,
  p_class_type text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_profile public.profiles%ROWTYPE;
  v_agency_name text;
  v_trip public.trips%ROWTYPE;
  v_id uuid;
  v_ref text;
  v_class text := lower(btrim(COALESCE(p_class_type, '')));
  v_amount numeric;
  v_passenger text;
  v_res public.reservations%ROWTYPE;
  v_class_enabled boolean;
BEGIN
  SELECT * INTO v_profile FROM public.profiles WHERE id = auth.uid();
  IF v_profile.id IS NULL OR v_profile.role::text <> 'agent' THEN RAISE EXCEPTION 'ACCES_REFUSE : cette action est réservée aux agents.'; END IF;
  IF v_profile.agency_id IS NULL THEN RAISE EXCEPTION 'AGENT_AGENCY_REQUIRED'; END IF;
  SELECT name INTO v_agency_name FROM public.agencies WHERE id = v_profile.agency_id AND status = 'active';
  IF v_agency_name IS NULL THEN RAISE EXCEPTION 'AGENT_AGENCY_REQUIRED'; END IF;
  IF v_class NOT IN ('vip', 'standard') THEN RAISE EXCEPTION 'INVALID_CLASS'; END IF;
  SELECT CASE WHEN v_class = 'vip'
    THEN s.booking_class_vip_enabled ELSE s.booking_class_standard_enabled END
    INTO v_class_enabled
    FROM public.site_settings s WHERE s.id = 1 FOR SHARE;
  IF NOT COALESCE(v_class_enabled, true) THEN RAISE EXCEPTION 'CLASS_DISABLED'; END IF;
  IF NULLIF(btrim(p_passenger_name), '') IS NULL
     OR NULLIF(btrim(p_passenger_first_name), '') IS NULL
     OR NULLIF(btrim(p_passenger_phone), '') IS NULL
     OR NULLIF(btrim(p_birth_place), '') IS NULL THEN
    RAISE EXCEPTION 'PASSENGER_DETAILS_REQUIRED';
  END IF;
  IF COALESCE(p_has_id_card, false)
     AND (NULLIF(btrim(p_id_card_type), '') IS NULL OR NULLIF(btrim(p_id_card_number), '') IS NULL) THEN
    RAISE EXCEPTION 'ID_CARD_DETAILS_REQUIRED';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_trip_id::text, 0));
  SELECT * INTO v_trip FROM public.trips WHERE id = p_trip_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'TRIP_NOT_FOUND'; END IF;
  IF v_trip.status NOT IN ('scheduled', 'boarding') THEN RAISE EXCEPTION 'TRIP_NOT_BOOKABLE'; END IF;
  IF v_trip.departure_date + v_trip.departure_time <= (clock_timestamp() AT TIME ZONE 'Africa/Brazzaville') THEN
    RAISE EXCEPTION 'TRIP_ALREADY_DEPARTED';
  END IF;
  IF v_trip.bus_id IS NULL THEN RAISE EXCEPTION 'BUS_NOT_ASSIGNED_OR_CAPACITY_INVALID'; END IF;

  v_ref := format('NZK-%s-%s', to_char(clock_timestamp(), 'YYYYMMDD'), lpad(nextval('public.ticket_number_seq')::text, 6, '0'));
  v_amount := CASE WHEN v_class = 'vip' THEN v_trip.price_vip ELSE v_trip.price_standard END;
  v_passenger := concat_ws(' ', btrim(p_passenger_first_name), btrim(p_passenger_name));
  INSERT INTO public.reservations (
    reference_code, trip_id, passenger_name, passenger_first_name, passenger_phone,
    birth_place, has_id_card, id_card_type, id_card_number, class_type,
    seat_number, amount, payment_method, qr_code_data, status, expires_at,
    booking_channel, agency_id, created_by, created_by_name, created_by_agency_name
  ) VALUES (
    v_ref, v_trip.id, btrim(p_passenger_name), btrim(p_passenger_first_name), btrim(p_passenger_phone),
    btrim(p_birth_place), COALESCE(p_has_id_card, false),
    CASE WHEN p_has_id_card THEN NULLIF(btrim(p_id_card_type), '') ELSE NULL END,
    CASE WHEN p_has_id_card THEN NULLIF(btrim(p_id_card_number), '') ELSE NULL END,
    v_class, NULL, v_amount, 'cash', v_ref, 'pending', clock_timestamp() + interval '24 hours',
    'agent', v_profile.agency_id, v_profile.id,
    COALESCE(v_profile.full_name, v_profile.email), v_agency_name
  ) RETURNING * INTO v_res;

  INSERT INTO public.audit_logs (
    user_id, user_name, role, agency_id, agency_name, action, module,
    entity_type, entity_id, old_values, new_values
  ) VALUES (
    v_profile.id, COALESCE(v_profile.full_name, v_profile.email), 'agent', v_profile.agency_id, v_agency_name,
    'CREATION_RESERVATION_AGENT', 'Réservations', 'Reservation', v_res.id::text, NULL,
    jsonb_build_object(
      'event_label', 'Billet vendu au guichet par un agent', 'booking_channel', 'agent',
      'reference_code', v_ref, 'passenger_name', v_passenger,
      'trip_number', v_trip.trip_number, 'route', concat_ws(' → ', v_trip.departure_city, v_trip.arrival_city),
      'trip_date', v_trip.departure_date, 'trip_time', v_trip.departure_time,
      'class_type', v_class, 'seat_number', NULL, 'amount', v_amount,
      'status', 'pending', 'agent_name', COALESCE(v_profile.full_name, v_profile.email),
      'agency_id', v_profile.agency_id, 'agency_name', v_agency_name,
      'reserved_at', v_res.created_at
    )
  );

  RETURN to_jsonb(v_res) || jsonb_build_object(
    'created_by_agency_name', v_agency_name,
    'trip', jsonb_build_object(
      'id', v_trip.id, 'trip_number', v_trip.trip_number,
      'departure_city', v_trip.departure_city, 'arrival_city', v_trip.arrival_city,
      'departure_time', v_trip.departure_time, 'arrival_time', v_trip.arrival_time,
      'departure_date', v_trip.departure_date, 'bus_id', v_trip.bus_id,
      'price_standard', v_trip.price_standard, 'price_vip', v_trip.price_vip,
      'available_seats', v_trip.available_seats, 'status', v_trip.status
    )
  );
END;
$function$;

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
    jsonb_build_object('event_label', 'Réservation expirée automatiquement après 24 heures',
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
