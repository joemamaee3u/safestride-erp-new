-- SafeStride ERP migration 01: authenticated point of sale
-- Run in Supabase SQL Editor. Does not delete existing data.
BEGIN;
CREATE TABLE IF NOT EXISTS public.erp_staff (
 user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
 role text NOT NULL CHECK(role IN ('admin','manager','employee')),
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.erp_staff ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Staff can see own role" ON public.erp_staff;
CREATE POLICY "Staff can see own role" ON public.erp_staff FOR SELECT TO authenticated USING (user_id = (select auth.uid()));
CREATE TABLE IF NOT EXISTS public.pos_sales (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 receipt_number bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
 location_id uuid NOT NULL REFERENCES public.locations(id),
 cashier_id uuid NOT NULL REFERENCES auth.users(id),
 subtotal numeric(14,2) NOT NULL,
 discount numeric(14,2) NOT NULL,
 tax numeric(14,2) NOT NULL,
 total numeric(14,2) NOT NULL,
 cogs numeric(14,2) NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.pos_sale_lines (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 sale_id uuid NOT NULL REFERENCES public.pos_sales(id),
 product_id uuid NOT NULL REFERENCES public.products(id),
 quantity integer NOT NULL CHECK(quantity>0),
 unit_price numeric(14,2) NOT NULL,
 unit_cost numeric(14,2) NOT NULL,
 line_subtotal numeric(14,2) NOT NULL
);
CREATE TABLE IF NOT EXISTS public.erp_journal (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 sale_id uuid NOT NULL REFERENCES public.pos_sales(id),
 account text NOT NULL,
 debit numeric(14,2) NOT NULL DEFAULT 0,
 credit numeric(14,2) NOT NULL DEFAULT 0,
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK(debit>=0 AND credit>=0)
);
CREATE INDEX IF NOT EXISTS pos_sales_date_idx ON public.pos_sales(created_at);
CREATE INDEX IF NOT EXISTS pos_sales_location_idx ON public.pos_sales(location_id);
CREATE INDEX IF NOT EXISTS pos_lines_sale_idx ON public.pos_sale_lines(sale_id);
ALTER TABLE public.pos_sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_sale_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.erp_journal ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Staff view sales" ON public.pos_sales;
CREATE POLICY "Staff view sales" ON public.pos_sales FOR SELECT TO authenticated USING (EXISTS(SELECT 1 FROM public.erp_staff s WHERE s.user_id=(select auth.uid())));
DROP POLICY IF EXISTS "Staff view sale lines" ON public.pos_sale_lines;
CREATE POLICY "Staff view sale lines" ON public.pos_sale_lines FOR SELECT TO authenticated USING (EXISTS(SELECT 1 FROM public.erp_staff s WHERE s.user_id=(select auth.uid())));
DROP POLICY IF EXISTS "Staff view journal" ON public.erp_journal;
CREATE POLICY "Staff view journal" ON public.erp_journal FOR SELECT TO authenticated USING (EXISTS(SELECT 1 FROM public.erp_staff s WHERE s.user_id=(select auth.uid())));

CREATE OR REPLACE FUNCTION public.erp_complete_pos_sale(
 p_location uuid, p_lines jsonb, p_discount_percent numeric DEFAULT 0, p_tax_percent numeric DEFAULT 16
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
 v_user uuid := auth.uid(); v_sale uuid; v_receipt bigint;
 v_subtotal numeric(14,2):=0; v_discount numeric(14,2); v_tax numeric(14,2); v_total numeric(14,2);
 v_cogs numeric(14,2):=0; v_line record; v_product record; v_balance record;
 v_qty integer; v_line_sub numeric(14,2); v_items integer:=0;
BEGIN
 IF v_user IS NULL OR NOT EXISTS(SELECT 1 FROM public.erp_staff WHERE user_id=v_user) THEN RAISE EXCEPTION 'Staff login required'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.locations WHERE id=p_location AND is_active) THEN RAISE EXCEPTION 'Invalid location'; END IF;
 IF p_lines IS NULL OR jsonb_typeof(p_lines)<>'array' OR jsonb_array_length(p_lines)=0 THEN RAISE EXCEPTION 'Cart is empty'; END IF;
 IF p_discount_percent IS NULL OR p_discount_percent<0 OR p_discount_percent>100 OR p_tax_percent IS NULL OR p_tax_percent<0 OR p_tax_percent>100 THEN RAISE EXCEPTION 'Invalid tax or discount'; END IF;
 -- Lock inventory in stable product-id order to avoid deadlocks.
 FOR v_line IN
  SELECT (e->>'product_id')::uuid AS product_id, sum((e->>'quantity')::integer)::integer AS qty
  FROM jsonb_array_elements(p_lines) e
  GROUP BY (e->>'product_id')::uuid ORDER BY 1
 LOOP
  v_qty:=v_line.qty;
  IF v_qty IS NULL OR v_qty<=0 THEN RAISE EXCEPTION 'Invalid quantity'; END IF;
  SELECT id,name,price,cost,is_active INTO v_product FROM public.products WHERE id=v_line.product_id;
  IF NOT FOUND OR NOT v_product.is_active OR v_product.price<=0 THEN RAISE EXCEPTION 'Product unavailable for POS'; END IF;
  SELECT quantity_on_hand,quantity_reserved INTO v_balance FROM public.inventory_balances
   WHERE product_id=v_line.product_id AND location_id=p_location FOR UPDATE;
  IF NOT FOUND OR v_balance.quantity_on_hand-v_balance.quantity_reserved<v_qty THEN
   RAISE EXCEPTION 'Insufficient available stock for %',v_product.name;
  END IF;
  v_line_sub:=round(v_product.price*v_qty,2);
  v_subtotal:=v_subtotal+v_line_sub;
  v_cogs:=v_cogs+round(v_product.cost*v_qty,2);
  v_items:=v_items+v_qty;
 END LOOP;
 v_discount:=round(v_subtotal*p_discount_percent/100,2);
 v_tax:=round((v_subtotal-v_discount)*p_tax_percent/100,2);
 v_total:=v_subtotal-v_discount+v_tax;
 INSERT INTO public.pos_sales(location_id,cashier_id,subtotal,discount,tax,total,cogs)
 VALUES(p_location,v_user,v_subtotal,v_discount,v_tax,v_total,v_cogs)
 RETURNING id,receipt_number INTO v_sale,v_receipt;
 FOR v_line IN
  SELECT (e->>'product_id')::uuid AS product_id, sum((e->>'quantity')::integer)::integer AS qty
  FROM jsonb_array_elements(p_lines) e GROUP BY (e->>'product_id')::uuid ORDER BY 1
 LOOP
  SELECT price,cost INTO v_product FROM public.products WHERE id=v_line.product_id;
  INSERT INTO public.pos_sale_lines(sale_id,product_id,quantity,unit_price,unit_cost,line_subtotal)
  VALUES(v_sale,v_line.product_id,v_line.qty,v_product.price,v_product.cost,round(v_product.price*v_line.qty,2));
  UPDATE public.inventory_balances SET quantity_on_hand=quantity_on_hand-v_line.qty,updated_at=now()
   WHERE product_id=v_line.product_id AND location_id=p_location;
  INSERT INTO public.inventory_movements(product_id,location_id,quantity_change,movement_type,reason_code,reference_id)
   VALUES(v_line.product_id,p_location,-v_line.qty,'SALE','POS',v_sale);
 END LOOP;
 -- Balanced journal: debit cash and COGS, credit revenue, tax liability and inventory.
 INSERT INTO public.erp_journal(sale_id,account,debit,credit) VALUES
 (v_sale,'Cash',v_total,0),
 (v_sale,'Sales revenue',0,v_subtotal-v_discount),
 (v_sale,'IVA payable',0,v_tax),
 (v_sale,'Cost of goods sold',v_cogs,0),
 (v_sale,'Inventory',0,v_cogs);
 RETURN jsonb_build_object('sale_id',v_sale,'receipt_number',v_receipt,'subtotal',v_subtotal,'discount',v_discount,'tax',v_tax,'total',v_total,'cogs',v_cogs,'units',v_items);
END $$;
REVOKE ALL ON FUNCTION public.erp_complete_pos_sale(uuid,jsonb,numeric,numeric) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.erp_complete_pos_sale(uuid,jsonb,numeric,numeric) TO authenticated;
COMMIT;
-- AFTER creating a user in Supabase Authentication > Users, authorize that user separately:
-- INSERT INTO public.erp_staff(user_id,role)
-- SELECT id,'admin' FROM auth.users WHERE email='YOUR_STAFF_EMAIL_HERE'
-- ON CONFLICT(user_id) DO UPDATE SET role='admin';
