# SafeStride ERP v2 — POS implementation

This release adds a real authenticated Point of Sale with multi-line items, barcode/SKU entry, discount, configurable IVA, stock deduction, receipt number and a balanced journal. It does **not** yet implement the other rubric modules.

## Order of setup
1. Keep a copy of the current GitHub files. Upload `index.html`, `styles.css`, `app.js`, `.nojekyll` from this folder to the **root** of the existing `safestride-erp-new` repository, replacing the older files. Do **not** upload `01_pos.sql` to a public site if you later add secrets or private data to it; this version contains no secrets.
2. In Supabase > SQL Editor, paste `01_pos.sql` and run it. Check for success. Do not rerun inventory seed scripts.
3. In Supabase > Authentication > Users, create a staff account with an email and password. Use a strong password; don't share it in ChatGPT. If email confirmation is required, confirm it.
4. In Supabase SQL Editor, run the following query with your real staff email (replace placeholder). This grants that specific account permission to sell:

```sql
INSERT INTO public.erp_staff(user_id,role)
SELECT id,'admin' FROM auth.users WHERE email='YOUR_STAFF_EMAIL_HERE'
ON CONFLICT(user_id) DO UPDATE SET role='admin';
```

5. Wait for GitHub Pages deployment, refresh website, open POS, sign in with staff credentials, select location, add items, and complete a test sale.
6. Verify in Supabase `pos_sales`, `pos_sale_lines`, `erp_journal`, `inventory_balances`, and `inventory_movements` that records agree. Journal debits must equal credits. Inventory should decrease only at the selected location.

## Notes
- Public users cannot execute the POS transaction successfully: the server checks the authenticated user's `erp_staff` membership.
- POS sales currently use the product `cost` field as cost of goods sold. This is not yet weighted-average costing. The financial reporting module is still pending.
- POS does not yet support returns or exchanges; those require separate, secure database operations.
- The checkout uses the server's current catalog price; clients cannot submit their own price or cost.
- Staff sessions are stored in browser sessionStorage, not permanent storage; sign in again after closing the browser.
- Existing product and inventory RPC reads remain publicly accessible as configured earlier. Do not expose cost data in a public RPC.
- All transactional writes occur in a single PostgreSQL function call and are rolled back on error.
- Use the same Supabase project URL and publishable key already saved in the browser. Never use a secret/service-role key in browser code.
