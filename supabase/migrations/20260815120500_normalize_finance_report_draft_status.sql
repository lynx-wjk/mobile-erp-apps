-- Migration: Normalize finance report draft status and enforce true item gross omzet & escrow payout
-- Migration ID: 20260815120500_normalize_finance_report_draft_status.sql

UPDATE public.marketplace_finance_reports 
SET status = 'pulled',
    note = 'Updated draft status to pulled for valid payout'
WHERE status = 'draft' 
  AND payout_amount > 0 
  AND report_type = 'order_settlement';
