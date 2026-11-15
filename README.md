# SafeStride ERP — static starter

This is a new, lightweight HTML/CSS/JavaScript frontend that uses the EXISTING Supabase project. It does not reset or alter any database records.

## Current scope
- Dashboard: real counts and inventory by location
- Inventory: live stock from `public.get_public_inventory()` RPC
- Product catalog: public active products
- Remaining ERP modules: explicitly labeled under development; **not** implemented

## Deployment on GitHub Pages
1. Create a NEW GitHub repository (e.g. `safestride-erp-new`). Do not overwrite the existing Lovable repository.
2. Upload `index.html`, `styles.css`, and `app.js` to the repository root.
3. In Settings > Pages, choose Deploy from a branch, branch `main`, folder `/ (root)`, then Save.
4. Visit the URL shown under Pages after deployment completes.
5. Click Database setup and enter your Supabase Project URL and **publishable/anon key only** (never service_role or secret key).

## Database requirements
The frontend calls:
- `GET /rest/v1/products?select=sku,name,category,barcode,price,reorder_point,is_active&is_active=eq.true&order=name.asc`
- `POST /rest/v1/rpc/get_public_inventory` via REST RPC endpoint (Supabase PostgREST supports calling stable no-arg functions via GET, as used here)

The SQL function `get_public_inventory()` was created previously. Verify it still exists and returns columns `sku, product_name, location_name, quantity_available`.

Your `products` RLS policy must permit read of published products. Do not expose private cost or customer data. The public availability RPC must expose only non-sensitive stock information.

## Important security and architecture notes
- This initial release is **read-only**. No anonymous inventory changes.
- Configuration is saved in the browser's localStorage, so the key must be a public publishable/anon key. Never enter secret keys.
- To satisfy your course requirements, future modules must use Supabase Auth, RLS, and transactional server-side PostgreSQL functions for multi-table writes.
- The app intentionally does not fabricate revenue, order histories, or working features.
