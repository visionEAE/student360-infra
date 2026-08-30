-- Events that stage 2 would publish to Pub/Sub, with the exact envelope a subscriber receives.
SELECT created_at, event_type, aggregate_type, aggregate_id, published_at, jsonb_pretty(payload) AS payload
FROM support.outbox_event
ORDER BY created_at DESC
LIMIT 10;
